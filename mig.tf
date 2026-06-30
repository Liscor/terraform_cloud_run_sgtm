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
