# ===========================================================================
# GCE MIG / VM backend for SGTM. All resources gated on var.use_mig.
# ===========================================================================

# Latest Container-Optimized OS stable image.
data "google_compute_image" "cos" {
  count   = var.use_mig ? 1 : 0
  family  = "cos-stable"
  project = "cos-cloud"
}

# Allow Google health-check / LB source ranges to reach the SGTM port.
resource "google_compute_firewall" "mig_health_checks" {
  count   = var.use_mig ? 1 : 0
  name    = "${var.name}-mig-allow-health-checks"
  network = var.mig_network

  allow {
    protocol = "tcp"
    ports    = ["8080"]
  }

  source_ranges = ["35.191.0.0/16", "130.211.0.0/22"]
  target_tags   = ["sgtm-mig"]

  depends_on = [google_project_service.compute_engine_api]
}

# LB backend health check: reacts fast so unhealthy VMs leave rotation quickly.
resource "google_compute_health_check" "mig_lb" {
  count               = var.use_mig ? 1 : 0
  name                = "${var.name}-mig-lb-health-check"
  check_interval_sec  = 5
  timeout_sec         = 4
  healthy_threshold   = 2
  unhealthy_threshold = 2

  http_health_check {
    request_path = "/healthy"
    port         = 8080
  }
}

# Autoheal health check: deliberately more tolerant so transient blips and the
# watchdog's own restart do not trigger full-VM recreate storms.
resource "google_compute_health_check" "mig_autoheal" {
  count               = var.use_mig ? 1 : 0
  name                = "${var.name}-mig-autoheal-health-check"
  check_interval_sec  = 30
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 5

  http_health_check {
    request_path = "/healthy"
    port         = 8080
  }
}

# Instance template shared by both MIGs (provisioning model differs per MIG,
# so each MIG references a per-provisioning template).
locals {
  mig_cloud_init = var.use_mig ? templatefile("${path.module}/templates/cloud-init.yaml.tftpl", {
    image              = "gcr.io/cloud-tagging-10302018/gtm-cloud-image:stable"
    container_config   = var.container_config
    project_id         = var.project_id
    preview_server_url = google_cloud_run_v2_service.gtm_preview.uri
  }) : ""
}

resource "google_compute_instance_template" "sgtm_primary" {
  count        = var.use_mig ? 1 : 0
  name_prefix  = "${var.name}-sgtm-primary-"
  machine_type = var.mig_machine_type
  tags         = ["sgtm-mig"]

  disk {
    source_image = data.google_compute_image.cos[0].self_link
    auto_delete  = true
    boot         = true
  }

  network_interface {
    network    = var.mig_network
    subnetwork = var.mig_subnetwork
    # No access_config block => no external IP. Traffic arrives via the LB.
  }

  service_account {
    email  = google_service_account.sgtm_service_account.email
    scopes = ["cloud-platform"]
  }

  metadata = {
    "user-data"              = local.mig_cloud_init
    "google-logging-enabled" = "true"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "google_compute_instance_template" "sgtm_overflow" {
  count        = var.use_mig ? 1 : 0
  name_prefix  = "${var.name}-sgtm-overflow-"
  machine_type = var.mig_machine_type
  tags         = ["sgtm-mig"]

  scheduling {
    provisioning_model = var.overflow_spot ? "SPOT" : "STANDARD"
    preemptible        = var.overflow_spot
    automatic_restart  = var.overflow_spot ? false : true
  }

  disk {
    source_image = data.google_compute_image.cos[0].self_link
    auto_delete  = true
    boot         = true
  }

  network_interface {
    network    = var.mig_network
    subnetwork = var.mig_subnetwork
  }

  service_account {
    email  = google_service_account.sgtm_service_account.email
    scopes = ["cloud-platform"]
  }

  metadata = {
    "user-data"              = local.mig_cloud_init
    "google-logging-enabled" = "true"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Primary regional MIG: fixed size, on-demand, sized to the CUD baseline.
resource "google_compute_region_instance_group_manager" "sgtm_primary" {
  count              = var.use_mig ? 1 : 0
  name               = "${var.name}-sgtm-primary"
  region             = var.region
  base_instance_name = "${var.name}-sgtm-primary"
  target_size        = var.mig_primary_size

  version {
    instance_template = google_compute_instance_template.sgtm_primary[0].self_link
  }

  named_port {
    name = "http"
    port = 8080
  }

  auto_healing_policies {
    health_check      = google_compute_health_check.mig_autoheal[0].id
    initial_delay_sec = 300
  }

  update_policy {
    type                         = "PROACTIVE"
    minimal_action               = "REPLACE"
    instance_redistribution_type = "PROACTIVE"
    max_surge_fixed              = 3
    max_unavailable_fixed        = 0
  }
}

# Overflow regional MIG: Spot by default, autoscaled, min=1 (warm spill target).
resource "google_compute_region_instance_group_manager" "sgtm_overflow" {
  count              = var.use_mig ? 1 : 0
  name               = "${var.name}-sgtm-overflow"
  region             = var.region
  base_instance_name = "${var.name}-sgtm-overflow"

  version {
    instance_template = google_compute_instance_template.sgtm_overflow[0].self_link
  }

  named_port {
    name = "http"
    port = 8080
  }

  auto_healing_policies {
    health_check      = google_compute_health_check.mig_autoheal[0].id
    initial_delay_sec = 300
  }

  update_policy {
    type                         = "PROACTIVE"
    minimal_action               = "REPLACE"
    instance_redistribution_type = "PROACTIVE"
    max_surge_fixed              = 3
    max_unavailable_fixed        = 0
  }
}

resource "google_compute_region_autoscaler" "sgtm_overflow" {
  count  = var.use_mig ? 1 : 0
  name   = "${var.name}-sgtm-overflow-autoscaler"
  region = var.region
  target = google_compute_region_instance_group_manager.sgtm_overflow[0].id

  autoscaling_policy {
    min_replicas    = 1
    max_replicas    = var.mig_overflow_max
    cooldown_period = 180

    load_balancing_utilization {
      target = 0.8
    }
  }
}

# Backend service for the MIG tier (EXTERNAL_MANAGED, required for `preference`).
# Primary = PREFERRED (filled first); overflow = DEFAULT (spill target).
resource "google_compute_backend_service" "mig" {
  count                 = var.use_mig ? 1 : 0
  name                  = "${var.name}-mig-backend"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  protocol              = "HTTP"
  port_name             = "http"
  timeout_sec           = 30
  security_policy       = google_compute_security_policy.policy[0].id
  health_checks         = [google_compute_health_check.mig_lb[0].id]

  # Drain in-flight requests for at least Spot's 30s preemption notice.
  connection_draining_timeout_sec = 60

  backend {
    group                 = google_compute_region_instance_group_manager.sgtm_primary[0].instance_group
    balancing_mode        = "RATE"
    max_rate_per_instance = var.max_rate_per_instance
    preference            = "PREFERRED"
    capacity_scaler       = 1.0
  }

  backend {
    group                 = google_compute_region_instance_group_manager.sgtm_overflow[0].instance_group
    balancing_mode        = "RATE"
    max_rate_per_instance = var.max_rate_per_instance
    preference            = "DEFAULT"
    capacity_scaler       = 1.0
  }
}

# Optional: periodically rolling-restart the primary MIG so instances re-pull
# the :stable image (mirrors the Cloud Run daily update cadence). Off by default.
resource "google_cloud_scheduler_job" "mig_refresh" {
  count       = var.use_mig && var.mig_scheduled_refresh ? 1 : 0
  name        = "${var.name}-mig-refresh"
  description = "Rolling-restart the SGTM primary MIG to re-pull the latest image."
  region      = var.region
  schedule    = var.update_interval
  time_zone   = "Europe/Berlin"

  http_target {
    http_method = "POST"
    uri         = "https://compute.googleapis.com/compute/v1/projects/${var.project_id}/regions/${var.region}/instanceGroupManagers/${google_compute_region_instance_group_manager.sgtm_primary[0].name}/applyUpdatesToInstances"
    body = base64encode(jsonencode({
      allInstances                = true
      mostDisruptiveAllowedAction = "REPLACE"
    }))

    headers = {
      "Content-Type" = "application/json"
    }

    oauth_token {
      service_account_email = google_service_account.sgtm_service_account.email
      scope                 = "https://www.googleapis.com/auth/cloud-platform"
    }
  }

  depends_on = [google_project_service.cloud_scheduler]
}

# The SA needs MIG-update rights to trigger the scheduled refresh. Granted only
# when the optional refresh is enabled (broad role; see README).
resource "google_project_iam_member" "mig_refresh_instance_admin" {
  count   = var.use_mig && var.mig_scheduled_refresh ? 1 : 0
  project = var.project_id
  role    = "roles/compute.instanceAdmin.v1"
  member  = "serviceAccount:${google_service_account.sgtm_service_account.email}"
}
