terraform {
  required_providers {
    google = {
      source = "hashicorp/google"
    }
  }
}

locals {
  cloudrun_neg = one(google_compute_region_network_endpoint_group.cloudrun_neg[*].id)
  ip_address = one(google_compute_global_address.default[*].address)
  backend_default_service = one(google_compute_backend_service.default[*].id)
  url_map  = one(google_compute_url_map.default[*].id)
  ssl_certificate = one(google_compute_managed_ssl_certificate.default[*].id)
  load_balancer_target = one(google_compute_target_https_proxy.default[*].id)
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# Enable required Google Cloud APIs
resource "google_project_service" "compute_engine_api" {
  count = var.use_load_balancer ? 1 : 0
  service = "compute.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "dns" {
  count = var.use_load_balancer ? 1 : 0
  project = var.project_id
  service = "dns.googleapis.com"
}

#Enable logging
resource "google_project_service" "logging" {
  service = "logging.googleapis.com"
  disable_on_destroy = false
}

#Enable IAM
resource "google_project_service" "iam_api" {
  service = "iam.googleapis.com"
  disable_on_destroy = false
}

#SET NETWORKING TIER
resource "google_compute_project_default_network_tier" "default" {
  count = var.use_load_balancer ? 1 : 0
  network_tier = "PREMIUM"
  depends_on = [
      google_project_service.compute_engine_api
  ]
}

#Cloud Run
resource "google_project_service" "run_api" {
  service = "run.googleapis.com"
  disable_on_destroy = false
}

#Health Check
resource "google_compute_health_check" "cloud_run_health_check" {
  count = var.use_load_balancer ? 1 : 0
  name = "cloud-run-health-check"
  check_interval_sec = 5
  timeout_sec        = 5
  healthy_threshold  = 2
  unhealthy_threshold = 2

  http_health_check {
    request_path = "/healthy"
    port         = "443"
  }
}

#SSL Create
resource "google_compute_managed_ssl_certificate" "default" {
  count = var.use_load_balancer ? 1 : 0
  name = "${var.name}-cert"
  managed {
    domains = ["${var.domain_name}"]
  }
}

#Network Endpoint Group
resource "google_compute_region_network_endpoint_group" "cloudrun_neg" {
  count = var.use_load_balancer ? 1 : 0
  provider              = google-beta
  name                  = "cloud-run-prod-backend"
  network_endpoint_type = "SERVERLESS"
  region                = var.region
  cloud_run {
    service = google_cloud_run_v2_service.gtm_production.name
  }
}

#Empty URL Map
resource "google_compute_url_map" "default" {
  count = var.use_load_balancer ? 1 : 0
  name            = "${var.name}-urlmap"
  default_service = local.backend_default_service
}

#Backend
resource "google_compute_backend_service" "default" {
  count = var.use_load_balancer ? 1 : 0
  name      = "${var.name}-backend"

  protocol  = "HTTP"
  port_name = "http"
  timeout_sec = 30
  custom_response_headers  = [
    "X-Gclb-Country:{client_region}",
    "X-Gclb-Region:{client_region_subdivision}",
    "X-Gclb-City:{client_city}",
    "X-Gclb-Citylatlong:{client_city_lat_long}"
  ]
  backend {
    group = local.cloudrun_neg
  }
}

resource "google_compute_target_https_proxy" "default" {
  count = var.use_load_balancer ? 1 : 0
  name   = "${var.name}-https-proxy"

  url_map          = local.url_map
  ssl_certificates = [
    local.ssl_certificate
  ]
}

#Load Balancer Configuration
resource "google_compute_global_address" "default" {
  count = var.use_load_balancer ? 1 : 0
  name = "${var.name}-address"
}

#Load Balancer Rule
resource "google_compute_global_forwarding_rule" "default" {
  count = var.use_load_balancer ? 1 : 0
  name   = "${var.name}-lb"

  target = local.load_balancer_target
  port_range = "443"
  ip_address = local.ip_address
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

resource "google_cloud_run_v2_service" "gtm_preview" {
    name     = var.service_name_preview
    location = var.region
    ingress = "INGRESS_TRAFFIC_ALL"
    labels = {
        stack = "sgtm",
        provider = "mohrstade"
    }
    deletion_protection = var.deletion_protection
    template {
        annotations = {
          "run.googleapis.com/startup-cpu-boost" = var.cpu_boost
        }
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
  name     = var.service_name_production
  location = var.region
  ingress = "INGRESS_TRAFFIC_ALL"
  labels = {
        stack = "sgtm",
        provider = "mohrstade"
    }
  deletion_protection = var.deletion_protection
  template {
    annotations = {
      "run.googleapis.com/startup-cpu-boost" = var.cpu_boost
    }
    service_account = google_service_account.sgtm_service_account.email
    scaling {
        min_instance_count = var.min_instance_count
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
            value = google_cloud_run_v2_service.gtm_preview.uri
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
  depends_on = [ google_cloud_run_v2_service.gtm_preview ]
}

resource "google_logging_project_exclusion" "cloud-run-log-exclusion" {
  name = "cloud-run-log-exclusion"
  description = "Exclude Cloud Run logs which are not severe."
  filter = var.cloud_run_exclusion_filter
  depends_on = [ google_cloud_run_v2_service.gtm_production ]
}

resource "google_cloud_run_service_iam_member" "prod_run_all_users" {
  service  = google_cloud_run_v2_service.gtm_production.name
  location = google_cloud_run_v2_service.gtm_production.location
  role     = "roles/run.invoker"
  member   = "allUsers"
  depends_on = [ google_cloud_run_v2_service.gtm_production ]
}

resource "google_cloud_run_service_iam_member" "debug_run_all_users" {
  service  = google_cloud_run_v2_service.gtm_preview.name
  location = google_cloud_run_v2_service.gtm_preview.location
  role     = "roles/run.invoker"
  member   = "allUsers"
  depends_on = [ google_cloud_run_v2_service.gtm_preview ]
}

resource "google_monitoring_notification_channel" "sgtm_notification_channels" {
  count = length(var.notification_users)
  display_name = var.notification_users[count.index].name
  type         = "email"
  labels = {
    email_address = var.notification_users[count.index].email
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
  lifecycle {
    create_before_destroy = true
  }
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

  notification_channels = [ for channel in google_monitoring_notification_channel.sgtm_notification_channels : channel.id ]
  depends_on = [ google_monitoring_notification_channel.sgtm_notification_channels, google_monitoring_uptime_check_config.sgtm_uptime_check ]
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
      filter =  var.cloud_function_update_filter
    }
  }
  alert_strategy {
    notification_rate_limit {
      period = "300s"
    }
  }
  notification_channels = [ for channel in google_monitoring_notification_channel.sgtm_notification_channels : channel.id ]
  depends_on = [ google_monitoring_notification_channel.sgtm_notification_channels ]
}

resource "google_monitoring_alert_policy" "sgtm_cpu_utilization_alert_policy" {
  display_name = "SGTM High CPU Utilization Alert"
  combiner     = "OR"
  conditions {
    display_name = "SGTM CPU Utilization > 60% for Production"
    condition_threshold {
      filter = <<-EOT
        metric.type="run.googleapis.com/container/cpu/utilizations" AND
        resource.type="cloud_run_revision" AND
        resource.label.service_name="${var.service_name_production}"
      EOT
      comparison = "COMPARISON_GT"
      threshold_value = 0.6
      duration = "300s"
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_PERCENTILE_99"
      }
    }
  }
  notification_channels = [ for channel in google_monitoring_notification_channel.sgtm_notification_channels : channel.id ]
  depends_on = [ google_monitoring_notification_channel.sgtm_notification_channels ]
}

resource "google_monitoring_alert_policy" "sgtm_instance_count_alert_policy" {
  display_name = "SGTM High Instance Count Alert"
  combiner     = "OR"
  conditions {
    display_name = "SGTM Instance Count Exceeds 80% of Maximum"
    condition_threshold {
      filter = <<-EOT
        metric.type="run.googleapis.com/container/instance_count" AND
        resource.type="cloud_run_revision" AND
        resource.label.service_name="${var.service_name_production}"
      EOT
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_MEAN"
      }
      comparison      = "COMPARISON_GT"
      threshold_value = var.alert_instance_count
      duration        = "300s"
    }
  }
  notification_channels = [ for channel in google_monitoring_notification_channel.sgtm_notification_channels : channel.id ]
  depends_on = [ google_monitoring_notification_channel.sgtm_notification_channels ]
}

resource "google_monitoring_alert_policy" "sgtm_request_latency_alert" {
  display_name = "SGTM High Request Latency Alert"
  combiner     = "OR"
  conditions {
    display_name = "SGTM Request Latency Exceeds 2 Seconds"
    condition_threshold {
      filter = <<-EOT
        metric.type="run.googleapis.com/request_latencies" AND
        resource.type="cloud_run_revision" AND
        resource.label.service_name="${var.service_name_production}"
      EOT
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_PERCENTILE_99"
      }
      comparison      = "COMPARISON_GT"
      threshold_value = 2000
      duration        = "300s"
    }
  }
  notification_channels = [ for channel in google_monitoring_notification_channel.sgtm_notification_channels : channel.id ]
  depends_on = [ google_monitoring_notification_channel.sgtm_notification_channels ]
}

resource "google_logging_metric" "sgtm_http_error_responses_metric" {
  name        = "http_error_responses"
  description = "Count of HTTP error responses for Cloud Run requests"
  filter      = <<EOT
    resource.type="cloud_run_revision"
    httpRequest.status>=400
  EOT
  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    labels {
      key         = "status_code"
      value_type  = "INT64"
      description = "The HTTP status code of the response."
    }
  }
  label_extractors = {
    "status_code" = "EXTRACT(httpRequest.status)"
  }
}

resource "google_monitoring_alert_policy" "sgtm_error_logs_alert" {
  display_name = "SGTM High HTTP Error Rate Alert"
  combiner     = "OR"
  conditions {
    display_name = "Error Rate Exceeds Threshold"
    condition_threshold {
      filter = <<-EOT
        metric.type="logging.googleapis.com/user/http_error_responses" AND
        resource.type="cloud_run_revision" AND
        resource.label.service_name="${var.service_name_production}"
      EOT
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_RATE"
      }
      comparison      = "COMPARISON_GT"
      threshold_value = 5.0
      duration        = "0s"
    }
  }
  notification_channels = [ for channel in google_monitoring_notification_channel.sgtm_notification_channels : channel.id ]
  depends_on = [ google_monitoring_notification_channel.sgtm_notification_channels, google_logging_metric.sgtm_http_error_responses_metric ]
}

# download cloud function files from github
resource "null_resource" "index_js" {
  triggers = {
    always_run = "${timestamp()}"
  }
  provisioner "local-exec" {
    command = "curl -L https://raw.githubusercontent.com/liscor/sgtm_cloud_run_updater/main/index.js --output ${path.module}/cf_function/index.js"
  }
}

resource "null_resource" "package_json" {
  triggers = {
    always_run = "${timestamp()}"
  }
  provisioner "local-exec" {
    command = "curl -L https://raw.githubusercontent.com/liscor/sgtm_cloud_run_updater/main/package.json --output ${path.module}/cf_function/package.json"
  }
}

data "archive_file" "function_zip" {
  type        = "zip"
  output_path = "${path.module}/cf_function/function.zip"
  source_dir  = "${path.module}/cf_function"
  excludes    = ["${path.module}/cf_function/function.zip"]

  depends_on = [null_resource.index_js,null_resource.package_json]
}

resource "google_storage_bucket" "bucket" {
  name     = var.google_storage_bucket_name
  location = "EU"
}

# Upload the Cloud Function source file
resource "google_storage_bucket_object" "source_files" {
  name   = "sgtm_cloud_run_updater"
  bucket = google_storage_bucket.bucket.name
  source = "cf_function/function.zip"
  depends_on = [ google_storage_bucket.bucket, data.archive_file.function_zip ]
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
  schedule         = var.update_interval
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
  schedule         = var.update_interval
  time_zone        = "Europe/Berlin"
  attempt_deadline = "320s"

  retry_config {
    retry_count = 1
  }

  http_target {
    http_method = "POST"
    uri         = google_cloudfunctions_function.sgtm_updater.https_trigger_url
    body        = base64encode("{\"project_id\":\"${var.project_id}\",\"region\":\"${var.region}\",\"service_name\":\"${google_cloud_run_v2_service.gtm_preview.name}\"}")
    headers = {
      "Content-Type" = "application/json"
    }
    oidc_token {
      service_account_email = google_service_account.sgtm_service_account.email
    }
  }
  depends_on = [ google_cloudfunctions_function.sgtm_updater,google_cloud_run_v2_service.gtm_preview ]
}

output "load_balancer_ip" {
  value = local.ip_address
}