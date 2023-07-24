terraform {
  required_providers {
    google = {
      source = "hashicorp/google"
      version = "4.74.0"
    }
  }
}

provider "google" {
  credentials = file(var.service_account_file)
  project = var.project_id
  region  = var.region
}

resource "google_project_service" "iam_api" {
  service = "iam.googleapis.com"
  disable_on_destroy = false
}

#Alerts
resource "google_project_service" "monitoring_api" {
  service = "monitoring.googleapis.com"
  disable_on_destroy = false
}

resource "google_service_account" "sgtm_service_account" {
  account_id   = "serversidegtm"
  display_name = "Serverside Google Tagmanager"
  depends_on = [ google_project_service.iam_api ]
}

resource "google_project_iam_member" "sgtm_add_roles" {
  for_each = toset([
    "roles/run.invoker"
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
    depends_on = [ google_project_iam_member.sgtm_add_roles ]
}

/*locals {
  my_service_url = google_cloud_run_v2_service.gtm_debug.uri
  depends_on = [ google_cloud_run_v2_service.gtm_debug ]
}*/

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
