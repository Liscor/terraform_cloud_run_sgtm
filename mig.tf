# ===========================================================================
# Dense GCE MIG / VM backend for sGTM. All resources gated on var.use_mig.
#
# One regional, multi-zone MIG runs N sGTM containers per VM (one per serving
# core; one core reserved for the OS + an in-VM nginx that fans out to the
# containers on ports 8081+). Autoscaled on request rate AND CPU, with a daily
# prewarm schedule, served behind the load balancer via the weighted url-map
# split with Cloud Run (var.mig_traffic_weight, wired in main.tf).
# ===========================================================================

locals {
  mig_network_tag = "sgtm-mig"
  mig_ports       = [for i in range(var.mig_containers_per_vm) : 8081 + i]

  mig_cloud_init = var.use_mig ? templatefile("${path.module}/templates/cloud-init-dense.yaml.tftpl", {
    image              = "gcr.io/cloud-tagging-10302018/gtm-cloud-image:stable"
    container_config   = var.container_config
    project_id         = var.project_id
    preview_server_url = google_cloud_run_v2_service.gtm_preview.uri
    ports              = local.mig_ports
  }) : ""
}

# Latest Container-Optimized OS stable image.
data "google_compute_image" "cos" {
  count   = var.use_mig ? 1 : 0
  family  = "cos-stable"
  project = "cos-cloud"
}

data "google_compute_subnetwork" "mig" {
  count  = var.use_mig ? 1 : 0
  name   = var.mig_subnetwork
  region = var.region
}

# Egress: VMs have no external IP, so outbound traffic (image pull on boot +
# tag-vendor calls at runtime) goes through Cloud NAT. Dynamic port allocation
# sizes ports per VM on demand (min->max) to avoid port exhaustion on high
# outbound-call volume; AUTO_ONLY lets NAT add external IPs as the fleet grows.
resource "google_compute_router" "mig" {
  count   = var.use_mig ? 1 : 0
  name    = "${var.name}-mig-router"
  region  = var.region
  network = var.mig_network

  depends_on = [google_project_service.compute_engine_api]
}

resource "google_compute_router_nat" "mig" {
  count                              = var.use_mig ? 1 : 0
  name                               = "${var.name}-mig-nat"
  router                             = google_compute_router.mig[0].name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"

  enable_dynamic_port_allocation = true
  min_ports_per_vm               = 128
  max_ports_per_vm               = 16384

  subnetwork {
    name                    = data.google_compute_subnetwork.mig[0].self_link
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }

  # Log NAT errors (e.g. port exhaustion / dropped egress) for observability; low cost at ERRORS_ONLY.
  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# Allow Google health-check / LB source ranges to reach the sGTM port, scoped by
# target tag so no other VM is affected.
resource "google_compute_firewall" "mig_health_checks" {
  count   = var.use_mig ? 1 : 0
  name    = "${var.name}-mig-allow-health-checks"
  network = var.mig_network

  allow {
    protocol = "tcp"
    ports    = ["8080"]
  }

  source_ranges = ["35.191.0.0/16", "130.211.0.0/22"]
  target_tags   = [local.mig_network_tag]

  depends_on = [google_project_service.compute_engine_api]
}

# Fast LB check: unhealthy VMs leave rotation quickly.
resource "google_compute_health_check" "mig_lb" {
  count               = var.use_mig ? 1 : 0
  name                = "${var.name}-mig-lb-hc"
  check_interval_sec  = 5
  timeout_sec         = 4
  healthy_threshold   = 2
  unhealthy_threshold = 2

  http_health_check {
    request_path = "/healthy"
    port         = 8080
  }
}

# Tolerant autoheal check: avoids full-VM recreate storms on transient blips.
resource "google_compute_health_check" "mig_autoheal" {
  count               = var.use_mig ? 1 : 0
  name                = "${var.name}-mig-autoheal-hc"
  check_interval_sec  = 30
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 5

  http_health_check {
    request_path = "/healthy"
    port         = 8080
  }
}

resource "google_compute_instance_template" "mig" {
  count        = var.use_mig ? 1 : 0
  name_prefix  = "${var.name}-mig-"
  machine_type = var.mig_machine_type
  tags         = [local.mig_network_tag]

  disk {
    source_image = data.google_compute_image.cos[0].self_link
    auto_delete  = true
    boot         = true
    disk_type    = "pd-balanced"
  }

  network_interface {
    network    = var.mig_network
    subnetwork = var.mig_subnetwork
    # No access_config => no external IP. Egress via the shared Cloud NAT.
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

# Regional MIG: spreads VMs across all zones in the region (EVEN). Autoscaled;
# size is owned by the autoscaler (target_size ignored).
resource "google_compute_region_instance_group_manager" "mig" {
  count              = var.use_mig ? 1 : 0
  name               = "${var.name}-mig"
  region             = var.region
  base_instance_name = "${var.name}-mig"

  version {
    instance_template = google_compute_instance_template.mig[0].self_link
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
    max_surge_fixed              = 3
    max_unavailable_fixed        = 0
    instance_redistribution_type = "PROACTIVE"
  }

  depends_on = [google_compute_router_nat.mig]

  lifecycle {
    ignore_changes = [target_size]
  }
}

resource "google_compute_region_autoscaler" "mig" {
  count  = var.use_mig ? 1 : 0
  name   = "${var.name}-mig-autoscaler"
  region = var.region
  target = google_compute_region_instance_group_manager.mig[0].id

  autoscaling_policy {
    min_replicas    = var.mig_min_replicas
    max_replicas    = var.mig_max_replicas
    cooldown_period = 120

    load_balancing_utilization {
      target = 0.8
    }

    # Safety net independent of per-request cost: if the container gets heavier
    # (more tags/transformations), request-rate scaling under-provisions because
    # max_rate_per_instance is static. CPU scaling catches real saturation.
    # The autoscaler scales on whichever signal is higher.
    cpu_utilization {
      target = 0.55
    }

    scaling_schedules {
      name                  = "prewarm-daily-peak"
      min_required_replicas = var.mig_prewarm_min_replicas
      schedule              = var.mig_prewarm_cron
      time_zone             = var.mig_time_zone
      duration_sec          = var.mig_prewarm_duration_sec
      disabled              = false
    }
  }
}

# MIG backend service. EXTERNAL_MANAGED (matches the LB scheme when use_mig is
# on), RATE balancing, single backend group. Named `mig` so the url-map weighted
# split in main.tf references it unchanged.
resource "google_compute_backend_service" "mig" {
  count                           = var.use_mig ? 1 : 0
  name                            = "${var.name}-mig-backend"
  load_balancing_scheme           = "EXTERNAL_MANAGED"
  protocol                        = "HTTP"
  port_name                       = "http"
  timeout_sec                     = 30
  security_policy                 = google_compute_security_policy.policy[0].id
  health_checks                   = [google_compute_health_check.mig_lb[0].id]
  connection_draining_timeout_sec = 60

  backend {
    group                 = google_compute_region_instance_group_manager.mig[0].instance_group
    balancing_mode        = "RATE"
    max_rate_per_instance = var.max_rate_per_instance
    capacity_scaler       = 1.0
  }
}

# Optional: periodically rolling-restart the MIG so instances re-pull the
# :stable image (mirrors the Cloud Run daily update cadence). Off by default.
resource "google_cloud_scheduler_job" "mig_refresh" {
  count       = var.use_mig && var.mig_scheduled_refresh ? 1 : 0
  name        = "${var.name}-mig-refresh"
  description = "Rolling-restart the sGTM MIG to re-pull the latest image."
  region      = var.region
  schedule    = var.update_interval
  time_zone   = var.mig_time_zone

  http_target {
    http_method = "POST"
    uri         = "https://compute.googleapis.com/compute/v1/projects/${var.project_id}/regions/${var.region}/instanceGroupManagers/${google_compute_region_instance_group_manager.mig[0].name}/applyUpdatesToInstances"
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
