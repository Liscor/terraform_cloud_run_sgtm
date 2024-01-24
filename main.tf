terraform {
  required_providers {
    google = {
      source = "hashicorp/google"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

#IAM
resource "google_project_service" "iam_api" {
  service = "iam.googleapis.com"
  disable_on_destroy = false
}


#Cloud Run
resource "google_project_service" "run_api" {
  service = "run.googleapis.com"
  disable_on_destroy = false
}

#Cloud Scheduler
resource "google_project_service" "cloud_scheduler" {
  service = "cloudscheduler.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "cloud_build" {
  service = "cloudbuild.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "cloud_functions" {
  service = "cloudfunctions.googleapis.com"
  disable_on_destroy = false
}

#Alerts
resource "google_project_service" "monitoring_api" {
  service = "monitoring.googleapis.com"
  disable_on_destroy = false
}

resource "google_service_account" "sgtm_service_account" {
  account_id   = "server-side-gtm"
  display_name = "Serverside Google Tagmanager"
  depends_on = [ google_project_service.iam_api ]
}

resource "google_project_iam_member" "sgtm_add_roles" {
  for_each = toset([
    "roles/run.invoker",
    "roles/cloudfunctions.invoker",
    "roles/cloudfunctions.serviceAgent"
    ])
  project = var.project_id
  role = each.value
  member = "serviceAccount:${google_service_account.sgtm_service_account.email}"
  depends_on = [ google_service_account.sgtm_service_account ]
}

resource "google_cloud_run_v2_service" "gtm_debug" {
    name     = "gtm-debug"
    location = var.region
    ingress = "INGRESS_TRAFFIC_ALL"
    labels = {
        stack = "sgtm",
        provider = "mohrstade"
    }
    template {
    
        service_account = google_service_account.sgtm_service_account.email
        scaling {
            min_instance_count = 0
            max_instance_count = 1
        }
        containers {
        image = "gcr.io/cloud-tagging-10302018/gtm-cloud-image:stable"
        env {
            name = "CONTAINER_CONFIG"
            value = var.container_config
        }
        env {
            name = "GOOGLE_CLOUD_PROJECT"
            value = var.project_id
        }
        env {
            name = "RUN_AS_PREVIEW_SERVER"
            value = true
        }
        startup_probe {
            http_get {
                path = "/healthy"
            }
            initial_delay_seconds = 0
            period_seconds = 10
            failure_threshold = 3
            timeout_seconds = 4
        }
        liveness_probe {
            http_get {
                path = "/healthy"
            }
            initial_delay_seconds = 240
            period_seconds = 10
            failure_threshold = 10
            timeout_seconds = 4
        }
        }
    }
    depends_on = [ google_project_iam_member.sgtm_add_roles, google_project_service.run_api ]
}

resource "google_cloud_run_v2_service" "gtm_production" {
  name     = "gtm-production"
  location = var.region
  ingress = "INGRESS_TRAFFIC_ALL"
  labels = {
        stack = "sgtm",
        provider = "mohrstade"
    }  
  template {
    
    service_account = google_service_account.sgtm_service_account.email
    scaling {
        min_instance_count = 0
        max_instance_count = var.max_instance_count
    }
    containers {
        image = "gcr.io/cloud-tagging-10302018/gtm-cloud-image:stable"
        env {
            name = "CONTAINER_CONFIG"
            value = var.container_config
        }
        env {
            name = "GOOGLE_CLOUD_PROJECT"
            value = var.project_id
        }
        env {
            name = "PREVIEW_SERVER_URL"
            value = google_cloud_run_v2_service.gtm_debug.uri
        }

       startup_probe {
        http_get {
          path = "/healthy"
        }
        initial_delay_seconds = 0
        period_seconds = 10
        failure_threshold = 3
        timeout_seconds = 4
      }
      liveness_probe {
        http_get {
          path = "/healthy"
        }
        initial_delay_seconds = 240
        period_seconds = 10
        failure_threshold = 10
        timeout_seconds = 4
      }
    }
  }
  depends_on = [ google_cloud_run_v2_service.gtm_debug ]
}
resource "google_cloud_run_service_iam_member" "prod_run_all_users" {
  service  = google_cloud_run_v2_service.gtm_production.name
  location = google_cloud_run_v2_service.gtm_production.location
  role     = "roles/run.invoker"
  member   = "allUsers"
  depends_on = [ google_cloud_run_v2_service.gtm_production ]
}

resource "google_cloud_run_service_iam_member" "debug_run_all_users" {
  service  = google_cloud_run_v2_service.gtm_debug.name
  location = google_cloud_run_v2_service.gtm_debug.location
  role     = "roles/run.invoker"
  member   = "allUsers"
  depends_on = [ google_cloud_run_v2_service.gtm_debug ]
}

resource "google_monitoring_notification_channel" "sgtm_notification_channel" {
  display_name = "${var.notification_user.name}"
  type         = "email"
  labels = {
    email_address = var.notification_user.email
  }
  force_delete = false
  depends_on = [ google_project_service.monitoring_api ]
}

resource "google_monitoring_uptime_check_config" "sgtm_uptime_check" {
  display_name = "sgtm_uptime_check"
  timeout = "10s"
  period = "60s"
  
  http_check {
    path     = "/healthy"
    port     = 443
    use_ssl  = true
  }

  monitored_resource {
    type = "cloud_run_revision"
    labels = {
      project_id = var.project_id
      service_name = google_cloud_run_v2_service.gtm_production.name
      location = var.region
    }
  }
  depends_on = [ google_cloud_run_v2_service.gtm_production ]
}

resource "google_monitoring_alert_policy" "sgtm_alert_policy" {
  display_name = "SGTM Alert Policy"
  combiner     = "OR"
  documentation {
    content = <<EOT
    Uptime Alert - Serverside Google Tag Manager
    There was an error for the Cloud Run services running the serverside Google Tag Manager backend in project: "${var.project_id}".

    Check the Uptime Checks in Monitoring on GCP for more information.
    EOT
    mime_type = "text/markdown"
  }
  conditions {
    display_name = "Failure of uptime check : ${google_monitoring_uptime_check_config.sgtm_uptime_check.uptime_check_id}"
    condition_threshold {
    filter = <<EOT
metric.type="monitoring.googleapis.com/uptime_check/check_passed" AND metric.label.check_id="${google_monitoring_uptime_check_config.sgtm_uptime_check.uptime_check_id}" AND resource.type="cloud_run_revision"
    EOT
    duration        = "60s"
    comparison      = "COMPARISON_GT"
    threshold_value = "1"
    trigger {
      count = "1"
    }

    aggregations {
      alignment_period     = "1200s"
      cross_series_reducer = "REDUCE_COUNT_FALSE"
      group_by_fields = [
        "resource.label.project_id",
        "resource.label.service_name",
        "resource.label.revision_name",
        "resource.label.location",
        "resource.label.configuration_name"
      ]
      per_series_aligner   = "ALIGN_NEXT_OLDER"
    }
  }    
  }

  notification_channels = [google_monitoring_notification_channel.sgtm_notification_channel.id]
  depends_on = [ google_monitoring_notification_channel.sgtm_notification_channel, google_monitoring_uptime_check_config.sgtm_uptime_check ]
}

resource "google_monitoring_alert_policy" "sgtm_update_alert_policy" {
  display_name = "SGTM Update Notice"
  combiner     = "OR"
  documentation {
    content = <<EOT
    SGTM Update Notice
    The Cloud Run SGTM in "${var.project_id}" was updated to the latest version.
    Check Cloud Function logs for details.
    
    EOT
    mime_type = "text/markdown"
  }
  conditions {
    display_name = "SGTM"
    condition_matched_log {
      filter =  var.cloud_run_logs_filter
    }
  }
  alert_strategy {
    notification_rate_limit {
      period = "300s"
    }  
  }
  notification_channels = [google_monitoring_notification_channel.notification_channel.id]
  depends_on = [ google_monitoring_notification_channel.sgtm_notification_channel ]
}

# We create Cloud Storage Bucket
resource "google_storage_bucket" "bucket" {
  name     = var.google_storage_bucket_name
  location = "EU"
}

# Upload the Cloud Function source file
resource "google_storage_bucket_object" "source_files" {
  name   = "cloud_function_src"
  bucket = google_storage_bucket.bucket.name
  source = "cloud_function_src.zip"
  depends_on = [ google_storage_bucket.bucket ]
}

# Create Cloud Function for updating
resource "google_cloudfunctions_function" "sgtm_updater" {
  name        = "sgtm_cloud_run_updater"
  description = "Cloud Function to update the Cloud Run sgtm if necessary."
  service_account_email = google_service_account.sgtm_service_account.email
  runtime     = "nodejs20"
  region = var.region
  available_memory_mb   = 256
  source_archive_bucket = google_storage_bucket.bucket.name
  source_archive_object = google_storage_bucket_object.source_files.name
  trigger_http          = true
  entry_point           = "check_cloud_run"
  depends_on = [ google_storage_bucket_object.source_files ]
}

# Triggers the sgtm cloud updater for gtm-production once a day 
resource "google_cloud_scheduler_job" "run_sgtm_updater_production" {
  name             = "run_sgtm_updater_production"
  description      = "Execute the SGTM Cloud Function on a daily basis to check for updates and deploy these as well."
  region           = var.region
  schedule         = "0 8 * * *"
  time_zone        = "Europe/Berlin"
  attempt_deadline = "320s"

  retry_config {
    retry_count = 1
  }

  http_target {
    http_method = "POST"
    uri         = google_cloudfunctions_function.sgtm_updater.https_trigger_url
    body        = base64encode("{\"project_id\":\"${var.project_id}\",\"region\":\"${var.region}\",\"service_name\":\"${google_cloud_run_v2_service.gtm_production.name}\"}")
    headers = {
      "Content-Type" = "application/json"
    }
    oidc_token {
      service_account_email = google_service_account.sgtm_service_account.email
    }
  }
  depends_on = [ google_cloudfunctions_function.sgtm_updater,google_cloud_run_v2_service.gtm_production ]
}

# Triggers the sgtm cloud updater for gtm-debug once a day 
resource "google_cloud_scheduler_job" "run_sgtm_updater_debug" {
  name             = "run_sgtm_updater_debug"
  description      = "Execute the SGTM Cloud Function on a daily basis to check for updates and deploy these as well."
  region           = var.region
  schedule         = "0 8 * * *"
  time_zone        = "Europe/Berlin"
  attempt_deadline = "320s"

  retry_config {
    retry_count = 1
  }

  http_target {
    http_method = "POST"
    uri         = google_cloudfunctions_function.sgtm_updater.https_trigger_url
    body        = base64encode("{\"project_id\":\"${var.project_id}\",\"region\":\"${var.region}\",\"service_name\":\"${google_cloud_run_v2_service.gtm_debug.name}\"}")
    headers = {
      "Content-Type" = "application/json"
    }
    oidc_token {
      service_account_email = google_service_account.sgtm_service_account.email
    }
  }
  depends_on = [ google_cloudfunctions_function.sgtm_updater,google_cloud_run_v2_service.gtm_debug ]
}