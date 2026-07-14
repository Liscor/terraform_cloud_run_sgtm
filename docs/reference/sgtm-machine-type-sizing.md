# sGTM MIG — machine-type sizing guideline

_Method: a single isolated VM behind the load balancer, driven with a GA4 `page_view` replay (k6),
watching VM CPU (Cloud Monitoring) and LB p95 latency while ramping request rate._

## TL;DR

1. **One sGTM container = one Node process = one CPU core.** It cannot use more than one vCPU. On a
   multi-vCPU VM the extra cores sit idle (measured: `e2-standard-2` capped ~54% = one of two cores;
   `c2d-highcpu-4` used ~17% = well under one of four). **Do not buy vCPUs a single container can't use.**
2. **Per-core speed varies ~2.5× across CPU families.** A modern core (c2d/c3/c4) does far more than an
   `e2` core for the same money. Prefer `*-highcpu` c-series.
3. **Absolute req/s depends on your container's tag load**, not just the machine. A light container does
   ~3× the req/s of a heavy one on the same core. **Pin `max_rate_per_instance` by load-testing _your_
   container** — don't copy a number from here.
4. **RAM is a non-factor** (~30 MiB/container idle, ~200 MiB under load). Use `highcpu` (2 GB/vCPU), never
   `standard`/`highmem`.

## Measured data (a light test container)

| Machine | vCPU | Core | Knee (p95 stays ~flat) | CPU at knee | ≈ ms CPU/req | Cost* |
|---|---|---|---|---|---|---|
| `e2-standard-2` | 2 | E2 (shared/variable) | **~110 req/s** | ~54% (= 1 core) | ~8.5 ms | ~€0.067/hr |
| `c2d-highcpu-4` | 4 | AMD Milan | **>200 req/s** (not reached; est. ~280/core) | ~17.5% at 200 rps | ~3.5 ms | ~€0.11/hr |

\*europe-west3 on-demand, approximate.

- At 200 req/s: `e2` p95 blew past 1 s and CPU maxed its one core; `c2d` held **p95 = 45 ms** at ~0.7 core.
- **Per-core: the c2d (Milan) core is ~2.4-2.5× an e2 core** for this workload.
- Cross-check with production (a heavy container, Cloud Run 1 vCPU): **~30-38 req/s per vCPU** —
  roughly 3× lower than this light container, illustrating point 3.

## Extrapolation rules

- **Within one CPU family, capacity scales by _cores actually used_, not vCPUs** — and one container uses
  one core. So a bigger single-container VM does **not** add capacity. To add capacity: **scale out**
  (more VMs via the MIG) or **run one container per vCPU** (see below).
- **Across families**, scale by per-core speed. Rough multipliers vs an `e2` core for this workload:
  c2d ≈ 2.5×, c3/c4 ≈ 3× (faster still, but see disk note). Do **not** carry req/s numbers across families.
- **For your workload**, multiply by (light-container knee ÷ your per-request CPU). Heavy container ⇒
  divide the table's req/s by ~3.

## Recommended approach

**Pragmatic (keep one container per VM):** use a **small `highcpu` c-series** VM and scale out.
`c2d-highcpu-2` (2 vCPU) gives one fast core for the container + one for OS/overhead, at low cost; let the
MIG autoscaler add VMs under load. Fast core → high per-VM throughput → fewer VMs.

**Max density (use all cores):** run **one container per vCPU** on the VM (cloud-init change: N containers
on distinct host ports, or the image's worker/cluster mechanism if available). Only then do multi-vCPU
VMs (`c2d-highcpu-4/8`) pay off. This mirrors Cloud Run's model (1 container ≈ 1 vCPU, scale by count).

Either way, **avoid `e2-standard-*`** for sGTM: slower cores **and** 4 GB/vCPU RAM you won't use.

**Smallest machine for serving = 2 vCPU dedicated-core** (e.g. `c2d-highcpu-2`): one core for the sGTM
container, one for OS/docker/health-check overhead. Don't go below this:
- **Shared-core** (`e2-micro/small/medium`) throttles to baseline under sustained load — dev/idle only.
- **1 vCPU dedicated** (`n1-standard-1`) is the theoretical floor, but the container then competes with the
  OS + LB/watchdog health probes for its single core → throttling and health-check flaps under load. Avoid.
- `e2-standard-2` is 2 dedicated vCPUs and *works*, but `e2-highcpu-2` (cheaper, 2 GB) or `c2d-highcpu-2`
  (faster core) are strictly better for the same footprint.

## Pinning `max_rate_per_instance`

It's the per-VM "full" threshold the LB uses for RATE balancing; it drives autoscaling (the MIG scales out
as VMs approach it). Set it to the **sustained per-VM knee of _your_ container on the chosen machine, minus
~20% headroom**:

1. Isolate one VM (set `mig_min_replicas = mig_max_replicas = 1` and `max_rate_per_instance` very high so the
   single VM absorbs all the traffic), deploy the machine type.
2. Ramp GA4 traffic with a load-test tool (e.g. k6 replaying a `page_view` hit), watch VM CPU (Cloud Monitoring) + LB p95 latency.
3. Knee = the req/s where p95 starts rising / CPU nears its one-core cap. `max_rate_per_instance ≈ 0.8 × knee`.

For the **light testbench** container: `e2-standard-2` → ~90; `c2d-highcpu-4` → ~220 (single container, so
the 4-vCPU value is not 2× the 2-vCPU value — it's the same one core, just faster). Re-measure for prod.

## Sizing by request/event volume (pick-a-machine table)

Because one container = one core, the per-**core** rate is what the table below lists. This module packs
`mig_containers_per_vm` containers per VM (default 3, one per serving core + one core for OS/nginx), so the
per-**VM** capacity is roughly `per-core rate × mig_containers_per_vm`. Set `max_rate_per_instance` (a
per-VM value) to that product, and let autoscaling handle total volume by scaling VMs *out*.

**Safe sustained req/s _per core_** (~80% of the measured/estimated knee); multiply by `mig_containers_per_vm`
for the per-VM figure to put in `max_rate_per_instance`:

| Machine (per serving core) | Heavy container¹ | Light container² | ≈ events/day per core³ (heavy → light) | Cost |
|---|---|---|---|---|
| `e2-micro` (dev/idle only ⚠︎) | ~9 req/s⁵ | ~25-30 req/s⁵ | ~0.3M → ~1.0M | ~€0.008/hr |
| `e2-small` (dev/idle only ⚠︎) | ~18 req/s⁵ | ~55 req/s⁵ | ~0.6M → ~2.0M | ~€0.017/hr |
| `e2-standard-2` / `e2-highcpu-2` (avoid) | ~28 req/s | ~90 req/s | ~1.0M → ~3.1M | ~€0.05-0.07/hr |
| **`c2d-highcpu-2`** (recommended) | **~65 req/s** | **~200 req/s** | **~2.2M → ~6.9M** | ~€0.055/hr |
| `c3-highcpu-2` / `c4-highcpu-2`⁴ | ~80 req/s | ~250 req/s | ~2.8M → ~8.6M | ~€0.06-0.09/hr |

¹ Heavy = many tags (~35 req/s per core, measured on Cloud Run for a heavy production container).
² Light = few tags, like the testbench (~110 req/s per e2 core, scaled by per-core speed).
³ events/day = sustained req/s × 86,400 (each request ≈ one GA4 event). **This is the *sustained* rate — size
for your PEAK, not your daily average** (see below).
⁴ c3/c4 need a `pd-balanced`/Hyperdisk boot disk (see Gotchas); c3 absent in `europe-west3-c`.
⁵ ⚠︎ **Shared/burstable core** (e2-micro ≈ 0.25 vCPU baseline, e2-small ≈ 0.5): bursts higher on credits
but sustained load throttles to baseline, so these numbers are unreliable to size against. Also e2-micro's
1 GB RAM is tight for the Node container + COS/docker overhead (OOM-flap risk). **Fine for dev/idle/parked
VMs; do not serve production traffic on shared-core.** Use a dedicated core (`c2d-highcpu-*`) for serving.

**Total capacity = per-VM rate × VMs.** e.g. `c2d-highcpu-4` with 3 heavy containers (~65 req/s/core ≈ 195
req/s/VM) scaling to 10 VMs ≈ 1,950 req/s. Set `mig_min_replicas` / `mig_max_replicas` to cover your peak.

**Sizing from a daily/monthly event count — worked example:**
1. Start from **peak** req/s, not the daily average. Real traffic peaks ~2-4× the daily-average rate.
   - Daily average rps = events_per_day ÷ 86,400. Peak rps ≈ that × 3 (use your own ratio if known).
2. VMs needed = peak req/s ÷ per-VM rate (from the table for your container weight).
3. Example: **50M events/day**, heavy container, `c2d-highcpu-2`:
   avg = 50M/86,400 ≈ 580 req/s → peak ≈ 1,740 req/s → 1,740 ÷ 65 ≈ **~27 VMs at peak**.
   Set `max_rate_per_instance ≈ 65` and let the MIG autoscale toward ~27–30.
   (Light container: 1,740 ÷ 200 ≈ ~9 VMs.)

**If you don't know your container's weight, treat it as heavy** (the conservative column) and re-measure
by load-testing once real traffic exists — tag load dominates, so measured beats estimated.

## Gotchas found during testing

- **Disk type couples to machine family.** The instance template uses `pd-balanced` (`mig.tf`), which works
  across `c2d`/`n2`/`e2`/`c3`/`n4`. `c4-*` needs Hyperdisk — switch `disk_type` in the template if you pick
  a `c4` machine. (Also: `c3` is not offered in `europe-west3-c`; `c4` is.)
- **Health check must probe from the host, not in-container.** The `gtm-cloud-image` is distroless (no
  shell/`wget`), so an in-container `--health-cmd 'wget ...'` can never run — the container gets marked
  unhealthy and a watchdog restart-loops it. The shipped `templates/cloud-init-dense.yaml.tftpl` avoids this
  by probing `/healthy` from the COS host with `curl`.
