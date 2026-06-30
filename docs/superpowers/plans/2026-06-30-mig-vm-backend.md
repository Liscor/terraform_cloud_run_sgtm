# GCE MIG/VM backend for SGTM with Cloud Run fallback — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an optional GCE Managed Instance Group backend (primary on-demand MIG + Spot overflow MIG) behind the existing global load balancer, with the existing Cloud Run service kept as a weight-controlled fallback, so production SGTM traffic can be moved off Cloud Run to cut compute cost.

**Architecture:** Everything new is gated behind `use_mig` (default `false`) so existing Cloud-Run-only deployments are untouched. When enabled, the LB is built as `EXTERNAL_MANAGED` (required for backend `preference`), routes a variable percentage (`mig_traffic_weight`, default `0`) to a `mig` backend service, and the rest to the existing Cloud Run NEG. The `mig` backend uses `preference = PREFERRED` on a fixed primary MIG and `DEFAULT` on an autoscaled Spot overflow MIG to get fill-then-spill. VMs run stock Container-Optimized OS with the SGTM container + a self-heal watcher injected via Terraform-rendered cloud-init.

**Tech Stack:** Terraform, `hashicorp/google` 7.14.1 + `google-beta`, GCE MIGs, Container-Optimized OS, cloud-init, global external Application Load Balancer (`EXTERNAL_MANAGED`).

**Spec:** [docs/superpowers/specs/2026-06-30-mig-vm-backend-design.md](../specs/2026-06-30-mig-vm-backend-design.md)

---

## Conventions for every task

- **Format gate:** `terraform fmt` (auto-fixes; commit the formatted result).
- **Validate gate:** `terraform validate` — requires `terraform init` already run; needs **no** cloud credentials. This is the primary per-task verification.
- **Plan gate (creds-required, where noted):** a real `terraform plan` against a project. Use a throwaway tfvars (`scratch.tfvars`, gitignored) so secrets never get committed. This is the acceptance check for behavioral tasks; if the executor has no GCP credentials, mark the plan-gate steps as deferred-to-rollout and rely on `validate`.
- Run all commands from the repo root.
- Commit after each task with the message shown.

> **One-time setup before Task 1:** run `terraform init` so `validate` works. The `.terraform.lock.hcl` already pins providers; do not upgrade them.

---

## File Structure

- **Create** `mig.tf` — all MIG-specific resources: extra API enables, firewall, two health checks, instance template, primary + overflow MIGs, overflow autoscaler, `mig` backend service, optional scheduled-refresh scheduler job.
- **Create** `templates/cloud-init.yaml.tftpl` — COS cloud-init: the container `systemd` unit and the self-heal watcher unit + script.
- **Modify** `variables.tf` — new variables (all default to "no change").
- **Modify** `main.tf` — add `locals` for LB scheme/backend selection; make the compute API + LB resources usable when `use_mig` is on; add the LB-scheme field to existing backend services / proxy / forwarding rule; convert the URL map to weighted routing when `use_mig`; add SA roles for logging/monitoring.
- **Modify** `terraform.tfvars` — commented examples for the new variables.
- **Modify** `README.md` — document the MIG feature, the CUD note, and the `EXTERNAL_MANAGED` migration caveat.
- **Modify** `.gitignore` — ignore `scratch.tfvars`.

---

## Task 1: Add new variables

**Files:**
- Modify: `variables.tf` (append at end)

- [ ] **Step 1: Append the new variables**

Add to the end of `variables.tf`:

```hcl
# ---------------------------------------------------------------------------
# MIG / VM backend (all default to "no change" so existing deploys are untouched)
# ---------------------------------------------------------------------------

variable "use_mig" {
  description = "Master switch: deploy the GCE MIG/VM backend behind the load balancer. Requires the load balancer to be enabled."
  type        = bool
  default     = false
}

variable "mig_traffic_weight" {
  description = "Percent of production traffic (0-100) routed to the MIG backend. The remainder goes to the Cloud Run fallback. 0 = all Cloud Run (test phase)."
  type        = number
  default     = 0

  validation {
    condition     = var.mig_traffic_weight >= 0 && var.mig_traffic_weight <= 100
    error_message = "mig_traffic_weight must be between 0 and 100."
  }
}

variable "machine_type" {
  description = "Machine type for the MIG VMs."
  type        = string
  default     = "e2-standard-2"
}

variable "mig_primary_size" {
  description = "Fixed instance count for the on-demand primary MIG (size to match committed-use baseline vCPUs)."
  type        = number
  default     = 1
}

variable "max_rate_per_instance" {
  description = "Requests/sec per instance that defines a backend as 'full' (LB RATE balancing). Pin this via a load test. Required when use_mig is true."
  type        = number
  default     = null
}

variable "mig_overflow_max" {
  description = "Maximum number of Spot overflow instances the autoscaler may create."
  type        = number
  default     = 3
}

variable "overflow_spot" {
  description = "true = Spot overflow VMs (max savings). false = on-demand overflow (zero data loss)."
  type        = bool
  default     = true
}

variable "mig_network" {
  description = "VPC network for the MIG VMs."
  type        = string
  default     = "default"
}

variable "mig_subnetwork" {
  description = "Subnetwork for the MIG VMs."
  type        = string
  default     = "default"
}

variable "mig_scheduled_refresh" {
  description = "If true, a Cloud Scheduler job periodically rolling-restarts the MIG so instances re-pull the :stable image."
  type        = bool
  default     = false
}
```

- [ ] **Step 2: Format and validate**

Run: `terraform fmt && terraform validate`
Expected: `Success! The configuration is valid.`

- [ ] **Step 3: Commit**

```bash
git add variables.tf
git commit -m "feat(mig): add MIG/VM backend variables"
```

---

## Task 2: Add locals and gating preconditions

**Files:**
- Modify: `main.tf` (the `locals` block at lines 9-17, and add a validation resource)

- [ ] **Step 1: Extend the `locals` block**

Add these entries inside the existing `locals { ... }` block in `main.tf`:

```hcl
  # When the MIG backend is enabled the LB must be the global external
  # Application Load Balancer (EXTERNAL_MANAGED) because backend `preference`
  # (fill-then-spill) is unsupported on the classic EXTERNAL scheme.
  lb_scheme = var.use_mig ? "EXTERNAL_MANAGED" : "EXTERNAL"

  # The compute API and LB are needed when either the LB or the MIG is enabled.
  enable_lb_stack = var.use_load_balancer || var.use_mig
```

- [ ] **Step 2: Add a precondition guard**

Add this resource to `main.tf` (anywhere top-level):

```hcl
# Guard rails for the MIG feature: enforce LB + required rate when use_mig is on.
resource "terraform_data" "mig_preconditions" {
  count = var.use_mig ? 1 : 0

  lifecycle {
    precondition {
      condition     = var.use_load_balancer
      error_message = "use_mig = true requires use_load_balancer = true (the MIG is served via the load balancer)."
    }
    precondition {
      condition     = var.max_rate_per_instance != null && var.max_rate_per_instance > 0
      error_message = "use_mig = true requires max_rate_per_instance to be set (> 0). Pin it via a load test."
    }
  }
}
```

- [ ] **Step 3: Format and validate**

Run: `terraform fmt && terraform validate`
Expected: `Success! The configuration is valid.`

- [ ] **Step 4: Commit**

```bash
git add main.tf
git commit -m "feat(mig): add LB-scheme local and use_mig preconditions"
```

---

## Task 3: Enable compute API for MIG and add SA roles

**Files:**
- Modify: `main.tf` (the `google_project_service.compute_engine_api` at lines 25-29; the `sgtm_add_roles` for_each at lines 271-281)

- [ ] **Step 1: Widen the compute API enable condition**

Change the count on `google_project_service.compute_engine_api` from:

```hcl
  count              = var.use_load_balancer ? 1 : 0
```

to:

```hcl
  count              = local.enable_lb_stack ? 1 : 0
```

Do the same for `google_project_service.dns`, `google_compute_project_default_network_tier.default`, and every existing LB resource currently gated on `var.use_load_balancer` (health check, SSL cert, NEG, URL map, backend services, security policy, https proxy, global address, forwarding rule) — replace `var.use_load_balancer ? 1 : 0` with `local.enable_lb_stack ? 1 : 0`. This makes the existing LB build whenever the MIG needs it.

> Note: `local` references in `count` are fine. After this change, enabling `use_mig` alone (with `use_load_balancer = false`) would fail the Task 2 precondition first, so in practice both are on together — but wiring the gate to `enable_lb_stack` keeps the graph correct.

- [ ] **Step 2: Add logging/monitoring roles to the SA**

In `google_project_iam_member.sgtm_add_roles`, extend the `toset([...])` to include the two writer roles the COS agents need:

```hcl
  for_each = toset([
    "roles/run.invoker",
    "roles/cloudfunctions.invoker",
    "roles/cloudfunctions.serviceAgent",
    "roles/artifactregistry.reader",
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter"
  ])
```

- [ ] **Step 3: Format and validate**

Run: `terraform fmt && terraform validate`
Expected: `Success! The configuration is valid.`

- [ ] **Step 4: Commit**

```bash
git add main.tf
git commit -m "feat(mig): enable compute stack for MIG and grant SA log/metric roles"
```

---

## Task 4: cloud-init template

**Files:**
- Create: `templates/cloud-init.yaml.tftpl`

- [ ] **Step 1: Write the cloud-init template**

Create `templates/cloud-init.yaml.tftpl`:

```yaml
#cloud-config

write_files:
  - path: /etc/systemd/system/sgtm.service
    permissions: "0644"
    owner: root
    content: |
      [Unit]
      Description=SGTM container
      Wants=gcr-online.target
      After=gcr-online.target

      [Service]
      Environment="HOME=/home/sgtm"
      ExecStartPre=/usr/bin/docker pull ${image}
      ExecStart=/usr/bin/docker run --rm --name=gtm \
        -p 8080:8080 \
        --health-cmd='wget -qO- http://localhost:8080/healthy || exit 1' \
        --health-interval=10s \
        --health-timeout=4s \
        --health-retries=3 \
        -e CONTAINER_CONFIG='${container_config}' \
        -e GOOGLE_CLOUD_PROJECT='${project_id}' \
        -e PREVIEW_SERVER_URL='${preview_server_url}' \
        ${image}
      ExecStop=/usr/bin/docker stop gtm
      Restart=always
      RestartSec=5

      [Install]
      WantedBy=multi-user.target

  - path: /opt/sgtm/watchdog.sh
    permissions: "0755"
    owner: root
    content: |
      #!/bin/bash
      # Restart the SGTM container if Docker reports it unhealthy.
      status=$(docker inspect --format='{{.State.Health.Status}}' gtm 2>/dev/null)
      if [ "$status" = "unhealthy" ]; then
        echo "$(date): Container gtm is unhealthy. Restarting." >> /var/log/sgtm-watchdog.log
        docker restart gtm
        echo "$(date): Container gtm has been restarted." >> /var/log/sgtm-watchdog.log
      fi

  - path: /etc/systemd/system/sgtm-watchdog.service
    permissions: "0644"
    owner: root
    content: |
      [Unit]
      Description=SGTM health watchdog (restart unhealthy container)
      After=sgtm.service

      [Service]
      Type=oneshot
      ExecStart=/opt/sgtm/watchdog.sh

  - path: /etc/systemd/system/sgtm-watchdog.timer
    permissions: "0644"
    owner: root
    content: |
      [Unit]
      Description=Run SGTM watchdog every 30s

      [Timer]
      OnBootSec=60s
      OnUnitActiveSec=30s
      AccuracySec=5s

      [Install]
      WantedBy=timers.target

runcmd:
  - systemctl daemon-reload
  - systemctl start sgtm.service
  - systemctl enable sgtm-watchdog.timer
  - systemctl start sgtm-watchdog.timer
```

- [ ] **Step 2: Verify the template references only the variables we will pass**

The template uses exactly these interpolations: `image`, `container_config`, `project_id`, `preview_server_url`. Confirm no others are present:

Run: `grep -oE '\$\{[a-z_]+\}' templates/cloud-init.yaml.tftpl | sort -u`
Expected output (exactly these four lines):
```
${container_config}
${image}
${preview_server_url}
${project_id}
```

- [ ] **Step 3: Commit**

```bash
git add templates/cloud-init.yaml.tftpl
git commit -m "feat(mig): add COS cloud-init template (container + self-heal watchdog)"
```

---

## Task 5: Firewall and health checks

**Files:**
- Create: `mig.tf`

- [ ] **Step 1: Start `mig.tf` with the COS image data source, firewall, and two health checks**

Create `mig.tf`:

```hcl
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
```

- [ ] **Step 2: Format and validate**

Run: `terraform fmt && terraform validate`
Expected: `Success! The configuration is valid.`

- [ ] **Step 3: Commit**

```bash
git add mig.tf
git commit -m "feat(mig): add COS image data source, firewall, and health checks"
```

---

## Task 6: Instance template

**Files:**
- Modify: `mig.tf` (append)

- [ ] **Step 1: Append the instance template**

```hcl
# Instance template shared by both MIGs (provisioning model differs per MIG,
# so each MIG references a per-provisioning template — see below).
locals {
  mig_cloud_init = var.use_mig ? templatefile("${path.module}/templates/cloud-init.yaml.tftpl", {
    image             = "gcr.io/cloud-tagging-10302018/gtm-cloud-image:stable"
    container_config  = var.container_config
    project_id        = var.project_id
    preview_server_url = google_cloud_run_v2_service.gtm_preview.uri
  }) : ""
}

resource "google_compute_instance_template" "sgtm_primary" {
  count        = var.use_mig ? 1 : 0
  name_prefix  = "${var.name}-sgtm-primary-"
  machine_type = var.machine_type
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
  machine_type = var.machine_type
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
```

> Two templates are used because Spot/preemptible scheduling differs between the
> primary (on-demand) and overflow (Spot-by-default) MIGs. They share the same
> cloud-init, image, machine type, tags, and SA.

- [ ] **Step 2: Format and validate**

Run: `terraform fmt && terraform validate`
Expected: `Success! The configuration is valid.`

- [ ] **Step 3: Commit**

```bash
git add mig.tf
git commit -m "feat(mig): add primary and overflow instance templates"
```

---

## Task 7: Primary and overflow MIGs + autoscaler

**Files:**
- Modify: `mig.tf` (append)

- [ ] **Step 1: Append the two regional MIGs and the overflow autoscaler**

```hcl
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
    type                  = "PROACTIVE"
    minimal_action        = "REPLACE"
    max_surge_fixed       = 3
    max_unavailable_fixed = 0
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
    type                  = "PROACTIVE"
    minimal_action        = "REPLACE"
    max_surge_fixed       = 3
    max_unavailable_fixed = 0
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
    cooldown_period = 60

    load_balancing_utilization {
      target = 0.8
    }
  }
}
```

> `min_replicas = 1` keeps one warm Spot instance so the LB always has a valid
> spill target and the autoscaler has a utilization signal to read (per spec).

- [ ] **Step 2: Format and validate**

Run: `terraform fmt && terraform validate`
Expected: `Success! The configuration is valid.`

- [ ] **Step 3: Commit**

```bash
git add mig.tf
git commit -m "feat(mig): add primary/overflow regional MIGs and overflow autoscaler"
```

---

## Task 8: `mig` backend service with fill-then-spill

**Files:**
- Modify: `mig.tf` (append)

- [ ] **Step 1: Append the MIG backend service**

```hcl
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
```

- [ ] **Step 2: Format and validate**

Run: `terraform fmt && terraform validate`
Expected: `Success! The configuration is valid.`

> If `validate` errors on `preference` being unknown, the provider is older than
> assumed — confirm `.terraform.lock.hcl` shows `hashicorp/google` >= 5.20 (it
> currently pins 7.14.1, which supports it).

- [ ] **Step 3: Commit**

```bash
git add mig.tf
git commit -m "feat(mig): add EXTERNAL_MANAGED backend service with fill-then-spill"
```

---

## Task 9: Migrate LB scheme and wire weighted routing

This is the most delicate task: the existing classic-LB resources gain the scheme field, and the URL map switches to weighted routing when `use_mig` is on.

**Files:**
- Modify: `main.tf` (backend services at 131-168; URL map at 109-128; https proxy 203-208; forwarding rule 217-223)

- [ ] **Step 1: Add the scheme field to the existing backend services, proxy, and forwarding rule**

In `google_compute_backend_service.scripts` and `google_compute_backend_service.default`, add this line (the value is `EXTERNAL` for existing deploys, `EXTERNAL_MANAGED` when the MIG is on, so existing deploys see no change):

```hcl
  load_balancing_scheme = local.lb_scheme
```

In `google_compute_target_https_proxy.default` no scheme field exists — leave it (https proxy works for both schemes).

In `google_compute_global_forwarding_rule.default`, add:

```hcl
  load_balancing_scheme = local.lb_scheme
```

> Migration caveat (document in README, Task 11): flipping `local.lb_scheme` from
> `EXTERNAL` to `EXTERNAL_MANAGED` on an existing deployment forces recreation of
> these resources. The reserved IP (`google_compute_global_address.default`) is
> preserved; the managed SSL cert re-provisions (~15-60 min).

- [ ] **Step 2: Convert the URL map to conditional weighted routing**

Replace the entire `google_compute_url_map.default` resource (lines 109-128) with:

```hcl
# URL Map. When use_mig is on, the default route splits weighted between the
# MIG backend and the Cloud Run backend. Otherwise it behaves as before
# (default_service = Cloud Run backend). The /gtm.js and /gtag/* script paths
# always stay on the CDN-backed Cloud Run scripts backend (cheap, cacheable).
resource "google_compute_url_map" "default" {
  count           = local.enable_lb_stack ? 1 : 0
  name            = "${var.name}-urlmap"
  default_service = var.use_mig ? null : local.backend_default_service

  dynamic "default_route_action" {
    for_each = var.use_mig ? [1] : []
    content {
      weighted_backend_services {
        backend_service = google_compute_backend_service.mig[0].id
        weight          = var.mig_traffic_weight
      }
      weighted_backend_services {
        backend_service = local.backend_default_service
        weight          = 100 - var.mig_traffic_weight
      }
    }
  }

  host_rule {
    hosts        = var.domain_names
    path_matcher = "scripts"
  }

  path_matcher {
    name            = "scripts"
    default_service = var.use_mig ? null : local.backend_default_service

    dynamic "default_route_action" {
      for_each = var.use_mig ? [1] : []
      content {
        weighted_backend_services {
          backend_service = google_compute_backend_service.mig[0].id
          weight          = var.mig_traffic_weight
        }
        weighted_backend_services {
          backend_service = local.backend_default_service
          weight          = 100 - var.mig_traffic_weight
        }
      }
    }

    path_rule {
      paths   = ["/gtm.js", "/gtag/*"]
      service = google_compute_backend_service.scripts[0].id
    }
  }
}
```

> Note: `path_rule.service` and weighted `default_route_action` cannot coexist on
> the same matcher level, but they are at different levels here (path_rule vs
> matcher default), which is valid. The script paths keep going to the CDN
> scripts backend regardless of weight.

- [ ] **Step 3: Format and validate**

Run: `terraform fmt && terraform validate`
Expected: `Success! The configuration is valid.`

- [ ] **Step 4 (plan gate, creds-required): confirm conditional behavior**

Create `scratch.tfvars` (gitignored) with real-ish values plus `use_mig = false`, run a plan, then flip `use_mig = true` + `max_rate_per_instance = 50` + `use_load_balancer = true` and plan again.

Run: `terraform plan -var-file=scratch.tfvars`
Expected (use_mig=false): no `google_compute_backend_service.mig`, no instance templates/MIGs; URL map uses `default_service`.
Expected (use_mig=true): plan shows the two MIGs, `mig` backend, weighted route action with weights `0` / `100`, and the LB resources changing `load_balancing_scheme` to `EXTERNAL_MANAGED`.

If no GCP credentials are available, skip this step and rely on `validate`; flag it for the rollout phase.

- [ ] **Step 5: Commit**

```bash
git add main.tf
git commit -m "feat(mig): migrate LB to EXTERNAL_MANAGED and add weighted MIG/Cloud Run routing"
```

---

## Task 10: Optional scheduled MIG refresh

**Files:**
- Modify: `mig.tf` (append)

- [ ] **Step 1: Append the optional scheduled-refresh job**

Reuse the existing Cloud Scheduler + SA. This job triggers a rolling restart of the primary MIG via the Compute API so long-lived instances re-pull `:stable`.

```hcl
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
    uri         = "https://compute.googleapis.com/compute/v1/projects/${var.project_id}/regions/${var.region}/instanceGroupManagers/${google_compute_region_instance_group_manager.sgtm_primary[0].name}/recreateInstances"

    oauth_token {
      service_account_email = google_service_account.sgtm_service_account.email
      scope                 = "https://www.googleapis.com/auth/cloud-platform"
    }
  }

  depends_on = [google_project_service.cloud_scheduler]
}
```

> The SA needs `roles/compute.instanceAdmin.v1` (or a narrower MIG-update role) to
> call `recreateInstances`. Add it to the `sgtm_add_roles` set **only if**
> scheduled refresh is used; documented in README. For the first cut
> (`mig_scheduled_refresh = false`) no extra role is required.

- [ ] **Step 2: Format and validate**

Run: `terraform fmt && terraform validate`
Expected: `Success! The configuration is valid.`

- [ ] **Step 3: Commit**

```bash
git add mig.tf
git commit -m "feat(mig): add optional scheduled MIG image refresh"
```

---

## Task 11: tfvars examples, .gitignore, and README

**Files:**
- Modify: `terraform.tfvars` (append)
- Modify: `.gitignore` (append)
- Modify: `README.md`

- [ ] **Step 1: Append commented examples to `terraform.tfvars`**

```hcl

# ---------------------------------------------------------------------------
# MIG / VM backend (optional, cost optimization). All off by default.
# ---------------------------------------------------------------------------
# use_mig             = true          # deploy the MIG backend (requires use_load_balancer = true)
# mig_traffic_weight  = 0             # 0 = all Cloud Run (test phase); ramp 10 -> 50 -> 100
# machine_type        = "e2-standard-2"
# mig_primary_size    = 1             # set to match committed-use baseline vCPUs
# max_rate_per_instance = 50          # REQUIRED when use_mig; pin via load test
# mig_overflow_max    = 3
# overflow_spot       = true          # false = on-demand overflow (zero data loss)
# mig_network         = "default"
# mig_subnetwork      = "default"
# mig_scheduled_refresh = false
```

- [ ] **Step 2: Add `scratch.tfvars` to `.gitignore`**

Append to `.gitignore`:

```
scratch.tfvars
```

- [ ] **Step 3: Add a README section**

Add under the Features list / a new "## MIG / VM backend (cost optimization)" section in `README.md`:

```markdown
## MIG / VM backend (cost optimization)

Optionally serve production traffic from a GCE Managed Instance Group of VMs
running the SGTM container, instead of Cloud Run, to cut compute cost. Cloud Run
is kept as a weight-controlled fallback.

- Enable with `use_mig = true` (requires `use_load_balancer = true`).
- Traffic is split via `mig_traffic_weight` (0-100). Start at `0` (all Cloud Run),
  load-test one instance to pin `max_rate_per_instance`, then ramp the weight.
  Drop it back to `0` for instant fail-back during MIG maintenance.
- The primary MIG is fixed-size (`mig_primary_size`) and on-demand; the overflow
  MIG is Spot (`overflow_spot = true`) and autoscaled. The LB fills the primary to
  `max_rate_per_instance` before spilling to the overflow.

### Committed Use Discounts (CUD)

This module does **not** purchase a CUD. Resource-based CUDs apply automatically
to matching running vCPUs in the region/family. Size `mig_primary_size` to match
the vCPUs you commit to, and buy the commitment separately in the billing console.

### Load balancer scheme migration

Enabling `use_mig` builds the load balancer as the global external Application
Load Balancer (`EXTERNAL_MANAGED`), required for the fill-then-spill `preference`
feature. On an existing classic-LB (`EXTERNAL`) deployment this **recreates** the
LB resources: the reserved IP is preserved, but the managed SSL certificate
re-provisions (allow ~15-60 min before HTTPS is healthy again).
```

- [ ] **Step 4: Format, validate, and commit**

Run: `terraform fmt && terraform validate`
Expected: `Success! The configuration is valid.`

```bash
git add terraform.tfvars .gitignore README.md
git commit -m "docs(mig): document MIG backend, CUD note, and LB scheme migration"
```

---

## Task 12: Full validation pass

**Files:** none (verification only)

- [ ] **Step 1: Format check (no diffs)**

Run: `terraform fmt -check -recursive`
Expected: no output (exit 0).

- [ ] **Step 2: Validate**

Run: `terraform validate`
Expected: `Success! The configuration is valid.`

- [ ] **Step 3 (creds-required): full plan both ways**

With `scratch.tfvars`, plan with `use_mig = false` then `use_mig = true` (+ `use_load_balancer = true`, `max_rate_per_instance = 50`). Confirm:
- `use_mig = false`: zero MIG resources planned; LB (if `use_load_balancer`) stays `EXTERNAL`.
- `use_mig = true`: primary + overflow MIGs, autoscaler, `mig` backend, weighted URL map, `EXTERNAL_MANAGED` on LB resources.

If no credentials, document this as the first step of the live rollout instead.

- [ ] **Step 4: No commit** (verification only). Branch is ready for review / PR.

---

## Rollout (post-merge, live — out of plan scope but recorded)

1. `apply` with `use_mig = true`, `mig_traffic_weight = 0` → MIG builds, instances go healthy, zero production traffic.
2. Load-test one instance → pin `max_rate_per_instance` and re-apply.
3. Ramp `mig_traffic_weight` `10 → 50 → 100`, watching latency / error rate / CPU.
4. For maintenance, set `mig_traffic_weight = 0` for instant fail-back to Cloud Run.

---

## Self-review notes (author)

- **Spec coverage:** routing/weighting (Task 9), EXTERNAL_MANAGED migration (Tasks 2, 9, 11), fill-then-spill preference (Task 8), overflow min=1 (Task 7), Spot toggle (Task 6), self-heal watcher + autoheal backstop (Tasks 4, 5, 7), separate LB vs autoheal health checks (Task 5), firewall ranges (Task 5), SA roles (Task 3), CUD doc (Task 11), test-phase default weight 0 (Task 1), image refresh (Task 10), file org `mig.tf` + template (Tasks 4-10). All spec sections map to a task.
- **Known live-only risks** (cannot be caught by `validate`): exact `default_route_action` + `path_rule` coexistence rules on `EXTERNAL_MANAGED` URL maps, and COS cloud-init systemd ordering — both must be confirmed in the Task 9/Task 12 plan gate or first live apply.
