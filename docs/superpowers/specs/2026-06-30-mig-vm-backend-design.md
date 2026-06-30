# Design: GCE MIG/VM backend for SGTM with Cloud Run fallback

**Date:** 2026-06-30
**Branch:** `feat/mig-vm-backend`
**Status:** Approved design — ready for implementation plan

## Goal

Cut SGTM serving cost (compute is the dominant line item) by moving production
traffic off Cloud Run and onto a GCE Managed Instance Group (MIG) of VMs running
the SGTM container, while keeping the existing Cloud Run production service as an
instant fallback for maintenance windows on the MIG.

The whole feature is integrated into this existing Terraform module and gated
behind a master switch so current Cloud-Run-only deployments are unaffected.

## Non-goals

- The **preview** SGTM service stays on Cloud Run only (low traffic, scales to
  zero). It is not moved to the MIG.
- The module does **not** purchase the Committed Use Discount (CUD). Resource-based
  CUDs apply automatically to matching running vCPUs in the region/family; they
  are not attached to a MIG. The fixed primary MIG just guarantees the baseline
  vCPUs exist to absorb a commitment bought separately in the billing console.
  This is documented in the README.
- No custom/baked VM image (no Packer). Stock Container-Optimized OS (COS) with
  everything injected at boot via Terraform-rendered `user-data` metadata.

## Architecture

```
   Client ──HTTPS──▶ Global external Application Load Balancer (EXTERNAL_MANAGED)
                     Cloud Armor + existing CDN (/gtm.js, /gtag/*)
                     URL map: weightedBackendServices (variable-driven)
                          │
        ┌─────────────────┴───────────────────────────┐
        │  backend service "mig"   weight=mig_traffic_weight
        │                          │  backend service "cloudrun"
        │                          │  weight = 100 - mig_traffic_weight
        ├──────────────────────────┤
        │  Primary MIG  (on-demand) │   Serverless NEG ──▶ Cloud Run
        │   preference = PREFERRED   │   gtm_production (existing)
        │   balancingMode RATE       │
        │   maxRatePerInstance = N   │
        │   fixed size (CUD baseline)│
        │                            │
        │  Overflow MIG (Spot)       │
        │   preference = DEFAULT      │
        │   balancingMode RATE        │
        │   autoscaled, min=1         │
        └────────────────────────────┘
```

**Normal operation:** `mig_traffic_weight = 100`. All production traffic hits the
`mig` backend service. The LB saturates the PREFERRED primary MIG up to
`max_rate_per_instance`, then spills the excess to the DEFAULT Spot overflow MIG.
Cloud Run sits idle (cold standby).

**Maintenance / fallback:** set `mig_traffic_weight` lower (e.g. `0`) and
`terraform apply`. Traffic shifts to Cloud Run while the MIGs are patched/rolled.
Because it is weight-based, gradual cutover (`0 → 10 → 50 → 100`) and instant
fail-back are both supported.

## Key technical decisions (and why)

### Load balancing scheme: EXTERNAL_MANAGED (required)

The fill-then-spill behavior depends on backend `preference`
(`PREFERRED`/`DEFAULT`): preferred backends must be filled to their balancing-mode
capacity before traffic goes to the rest. **`preference` is only supported on the
global external Application Load Balancer (`load_balancing_scheme =
EXTERNAL_MANAGED`), not on the classic external HTTP(S) LB (`EXTERNAL`).**

The existing module's backend services set no `load_balancing_scheme` and so
default to classic `EXTERNAL`. Therefore, when `use_mig = true`, the LB
(backend services, URL map, target proxy, forwarding rule) is built as
`EXTERNAL_MANAGED`.

> Migration note: enabling this on an existing classic-LB deployment recreates the
> LB resources. The reserved global IP is preserved via
> `google_compute_global_address`; the managed SSL certificate re-provisions
> (~15–60 min). Document this in the README.

Verified against Google Cloud Load Balancing docs (backend services overview /
load balancer feature comparison), 2026-06-30.

### Capacity overflow, not proportional split

With `balancing_mode = RATE` + `max_rate_per_instance` alone (no `preference`),
the global ALB distributes traffic **proportionally to capacity** across both
MIGs — Spot would take traffic immediately. `preference = PREFERRED` on the
primary and `DEFAULT` on the overflow is what produces fill-then-spill.

### Overflow MIG min = 1

A 0-instance backend is not a valid spill target and gives the autoscaler no
utilization signal to read, so the first burst past primary capacity would drop.
One always-warm Spot instance bootstraps both spill and autoscaling.

Residual risk: a regional Spot shortage can prevent even the warm floor from
coming up. Mitigation for now is the `overflow_spot` toggle (flip the whole
overflow tier to on-demand). A dedicated on-demand floor + Spot-on-top "mix" was
considered and **deferred** (would require a third MIG and more tuning; not needed
for the test-phase-first rollout).

### Spot vs on-demand overflow

`overflow_spot = true` (default) = max savings; Spot preemption can occasionally
drop a few tagging hits. `overflow_spot = false` = on-demand overflow for the
zero-data-loss posture. Connection-draining timeout is set to **60s** (≥ Spot's
30s preemption notice) so in-flight requests drain cleanly.

## Compute layer

A single **instance template** is the basis for both MIGs:

- Stock COS image, `machine_type` (default `e2-standard-2` — dedicated vCPUs, no
  burst-credit cliffs, so load-test numbers are representative).
- Same env as Cloud Run production: `CONTAINER_CONFIG`, `GOOGLE_CLOUD_PROJECT`,
  `PREVIEW_SERVER_URL` (→ existing preview Cloud Run service).
- Named port `http: 8080` (SGTM listen port) for the backend service to target.
- `sgtm_service_account` (reused), plus `roles/logging.logWriter` and
  `roles/monitoring.metricWriter` for log/metric shipping and the autoscaler.
- Network tag `sgtm-mig` (firewall targeting).
- `user-data` metadata = Terraform-rendered cloud-init (see Self-healing).

Two **regional** (multi-zone) MIGs from that template:

| | Primary MIG | Overflow MIG |
|---|---|---|
| Provisioning | on-demand (`STANDARD`) | Spot (`provisioning_model = SPOT`), toggle via `overflow_spot` |
| Size | fixed = `mig_primary_size` | autoscaled, `min = 1` → `max = mig_overflow_max` |
| Autoscaler | none | on LB serving-capacity utilization (`max_rate_per_instance`) |
| Backend preference | `PREFERRED` | `DEFAULT` |
| Balancing mode | `RATE`, `max_rate_per_instance` | `RATE`, `max_rate_per_instance` |
| Role | CUD-backed baseline | cheap peak absorption |

Both attach to the **`mig` backend service** (`EXTERNAL_MANAGED`).

## Self-healing on COS

Two layers (fast in-VM restart + MIG autoheal backstop).

**Layer 1 — in-VM watcher (fast path).** Terraform-rendered cloud-init in
`user-data` writes two systemd units on boot:

- `sgtm.service` runs the container:
  `docker run --name gtm-... -p 8080:8080 --health-cmd 'wget -qO-
  http://localhost:8080/healthy || exit 1' --health-interval=10s -e
  CONTAINER_CONFIG=... -e GOOGLE_CLOUD_PROJECT=... -e PREVIEW_SERVER_URL=...
  <image>`. The `--health-cmd` is defined by us — the base image is not guaranteed
  to declare a Docker `HEALTHCHECK`, and the watcher depends on
  `.State.Health.Status` being populated.
- `sgtm-watchdog.timer` + `.service` run the user's existing restart script every
  30s, re-pathed for COS (log to `/var/log/sgtm-watchdog.log`; `/root` and most of
  the root fs are read-only on COS):

  ```sh
  status=$(docker inspect --format='{{.State.Health.Status}}' gtm-... 2>/dev/null)
  if [ "$status" = "unhealthy" ]; then
    echo "$(date): unhealthy, restarting" >> /var/log/sgtm-watchdog.log
    docker restart gtm-...
  fi
  ```

**Layer 2 — MIG autohealing (backstop).** Autohealing policy with a generous
`initial_delay_sec` recreates a VM only if it stays unhealthy past threshold
(Docker daemon wedged, kernel dead, watcher broken). Fast restarts handle the
common case in seconds; full recreate is the rare last resort.

**Separate health-check resources.** The LB backend health check (controls
traffic; reacts fast to pull from rotation) and the MIG autoheal check (controls
recreate; deliberately slower/more tolerant to avoid recreate storms during a
transient blip or the watcher's own restart) are distinct resources. The container
health endpoint is `/healthy` on port 8080 (matches existing Cloud Run probes).

## Networking, firewall, service account

- **Network:** `mig_network` / `mig_subnetwork` variables (default `"default"`);
  no forced new VPC.
- **Firewall:** ingress rule allowing Google health-check / LB source ranges
  `35.191.0.0/16` and `130.211.0.0/22` to reach tcp:8080 on instances tagged
  `sgtm-mig`. Without it, LB health and MIG autohealing both report unhealthy →
  recreate loop. No public ingress to VMs; only the LB and health checkers reach
  them.
- **Service account:** reuse `sgtm_service_account` (already has `run.invoker`,
  `artifactregistry.reader`). Add `roles/logging.logWriter` and
  `roles/monitoring.metricWriter`. The SGTM image is the public Google image
  (`gcr.io/cloud-tagging-10302018/gtm-cloud-image:stable`), so no extra pull perms.

## Image updates on the VMs

- The existing Cloud Function updater targets Cloud Run only and is unchanged.
- VMs pull `:stable` at boot, so refreshing = rolling the MIG.
- **Rolling update** via MIG `update_policy` (`type = PROACTIVE`, surge/unavailable
  limits) replaces instances gradually with zero downtime when the template/image
  changes.
- **Optional scheduled refresh** (`mig_scheduled_refresh = false` by default):
  reuse Cloud Scheduler to trigger a periodic MIG rolling-restart so long-lived
  instances re-pull `:stable`, mirroring the daily Cloud Run cadence.

## Variables & gating

All new variables default to "no change" so existing deployments are untouched.

| Variable | Default | Purpose |
|---|---|---|
| `use_mig` | `false` | Master switch for the whole MIG stack |
| `mig_traffic_weight` | `0` | % of production traffic to the MIG backend (test-phase = 0 = all Cloud Run) |
| `machine_type` | `e2-standard-2` | VM size |
| `mig_primary_size` | `1` | Fixed CUD-baseline instance count (set to match committed vCPUs) |
| `max_rate_per_instance` | (required when `use_mig`) | LB "full" threshold; pin via load test |
| `mig_overflow_max` | `3` | Spot overflow autoscaler ceiling |
| `overflow_spot` | `true` | Spot (max savings) vs on-demand (zero data loss) |
| `mig_network` | `"default"` | VPC network |
| `mig_subnetwork` | `"default"` | Subnetwork |
| `mig_scheduled_refresh` | `false` | Periodic re-pull of `:stable` |

When `use_mig = true`: the LB is required and built as `EXTERNAL_MANAGED`. A
`precondition` enforces that `use_load_balancer`/LB is enabled and that
`max_rate_per_instance` is set.

## File organization

- New resources in a dedicated **`mig.tf`** (instance template, two MIGs,
  autoscaler, health checks, firewall, `mig` backend service, URL-map weighting).
- **`templates/cloud-init.yaml.tftpl`** for the COS config (systemd units + the
  watcher script), rendered with `templatefile()`.
- New variables appended to `variables.tf`; new tfvars examples in
  `terraform.tfvars`.
- Keeps `main.tf` from growing further and isolates the feature.

## Rollout plan (test-phase first)

1. `terraform apply` with `use_mig = true`, `mig_traffic_weight = 0`. The MIG
   stack builds, instances self-validate (health checks green), and receive **zero**
   production traffic — Cloud Run keeps serving everything.
2. Load-test a single instance to find the requests/sec where CPU sits ~70% with
   acceptable latency. Pin `max_rate_per_instance` and autoscaler target from that.
3. Ramp `mig_traffic_weight` `10 → 50 → 100` over successive applies, watching
   latency / error-rate / CPU.
4. For maintenance, drop `mig_traffic_weight` to `0` for instant fail-back to
   Cloud Run.

## Open items to resolve in the implementation plan

- Exact COS cloud-init syntax for declaring the two systemd units and the
  container run command (write-files + runcmd vs. systemd cloud-init module).
- Whether the existing Cloud Armor policy and CDN-backed scripts backend need any
  `EXTERNAL_MANAGED` adjustments when the scheme migrates.
- Confirm `google_compute_backend_service` `backend { preference = ... }` attribute
  name/availability in the pinned provider version (.terraform.lock.hcl).
