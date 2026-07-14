# Serverside Google Tag Manager - Terraform Cloud Run Deployment

This Terraform script deploys the serverside Google Tag Manager on Cloud Run within the Google Cloud Platform with various extra features like automated updates and an alerting policy.

## Features

- Uptime Check with Notifications - You will be notified if there is an outage of your SGTM services
- Docker Image Auto Updates - The SGTM Docker image will be updated automatically once per week (default)
- Log Exculusion - Logs with the serverity default or notice will be excluded to reduce costs
- Optional basic load balancer setup enabled via setting use_load_balancer variable to true.
- The Load balancer contains the Geolocation headers described [here](https://developers.google.com/tag-platform/tag-manager/server-side/enable-region-specific-settings) and the additonal ones neccesary for sending geolocation data to GA4 described [here](https://www.simoahava.com/gtm-tips/utilize-app-engine-headers-server-side-tagging/) All possible headers are listed [here](https://cloud.google.com/load-balancing/docs/https/custom-headers)

## MIG / VM backend (cost optimization)

Optionally serve production traffic from a regional GCE Managed Instance Group of
VMs running the SGTM container, instead of Cloud Run, to cut compute cost. Cloud
Run is kept as a weight-controlled fallback.

- Enable with `use_mig = true` (requires `use_load_balancer = true`).
- Traffic is split via `mig_traffic_weight` (0-100). Start at `0` (all Cloud Run),
  load-test one instance to pin `max_rate_per_instance`, then ramp the weight.
  Drop it back to `0` for instant fail-back during MIG maintenance.
- **Dense packing:** each VM runs `mig_containers_per_vm` SGTM containers (one per
  serving core; one core is reserved for the OS and an in-VM nginx that fans out
  to the containers). Fewer, bigger VMs cost less per request than many small ones.
- **Regional & multi-zone:** the MIG spreads VMs across all zones in `region`, so a
  single-zone outage does not take the tier down (autohealing recreates elsewhere).
- **Autoscaling:** scales on whichever is higher of request rate (vs
  `max_rate_per_instance`) and CPU, between `mig_min_replicas` and
  `mig_max_replicas`. A daily schedule pre-warms `mig_prewarm_min_replicas` VMs
  before the morning peak (`mig_prewarm_cron` / `mig_prewarm_duration_sec`, in
  `mig_time_zone`) so the ramp never waits on VM boot time.
- Self-healing: each VM runs the containers under systemd plus a per-container
  watchdog that restarts one if it reports unhealthy; MIG autohealing recreates a
  VM that stays unhealthy.

### Committed Use Discounts (CUD)

This module does **not** purchase a CUD. Resource-based CUDs apply automatically
to matching running vCPUs in the region/family. Size `mig_min_replicas` and the
machine type to match the vCPUs you commit to, and buy the commitment separately
in the billing console.

### Load balancer scheme migration

Enabling `use_mig` builds the load balancer as the global external Application
Load Balancer (`EXTERNAL_MANAGED`). On an existing classic-LB (`EXTERNAL`)
deployment this **recreates** the LB resources: the reserved IP is preserved, but
the managed SSL certificate re-provisions (allow ~15-60 min before HTTPS is
healthy again).

### Optional scheduled image refresh

Setting `mig_scheduled_refresh = true` adds a Cloud Scheduler job that rolls the
MIG on `update_interval` so instances re-pull the `:stable` image. This also
grants the SGTM service account `roles/compute.instanceAdmin.v1` (needed to
trigger the rolling update) — a broad role, enabled only when you opt in.

## Getting Started

### Quick Start

1. Clone this repository and make sure you have installed [Terraform](https://developer.hashicorp.com/terraform/tutorials/gcp-get-started/install-cli).
2. Authenticate with Application Default Credentials - Setup [Application Default Credentials](https://cloud.google.com/docs/authentication/provide-credentials-adc#local-user-cred).
3. Change the variables inside terraform.tfvars.example to suit your needs and rename the file to terraform.tfvars. Make sure you have created the SGTM Container already to retrieve the container config.
4. Run `terraform init` to initialize the repository and `terraform apply` the infrastructure will be built on GCP

### Run in Google Cloud Shell
1. Use This link to the [Cloud Shell](https://console.cloud.google.com/cloudshell/open?git_repo=https://github.com/Liscor/terraform_cloud_run_sgtm&page=editor&open_in_editor=terraform.tfvars)
   1. If you want the Cloud Shell Instance to not be persistant use this link: [non-persistant Cloud Shell](https://console.cloud.google.com/cloudshell/open?git_repo=https://github.com/Liscor/terraform_cloud_run_sgtm&page=editor&open_in_editor=terraform.tfvars&ephemeral=true).
2. Trust the Repo and Confirm when prompted.
3. Wait till Cloud Shell has completed loading. You should see the terraform.tfvars File.
4. Run `bash run_this.sh` 
   1. Click Authorize when asked to Authorize Cloud Shell.
   2. Hit `1` to initialize with new settings
   3. Hit `1` to sign in or sign in manually to the Google Account you want to use.
   4. Enter the project ID, create a new project or choose from the list of projects the one you want to use.
   5. Hit `y` to proceed. This Cloud Shell Instance is Ephemeral, it destroys itself after 20 Minutes of inactivity.
   6. Click the Link that is shown, choose the desired Google Account, sign in to Google Auth Library and grant access.
   7. Click the `Copy` Button and paste to Google Cloud Shell.
   8. You should now see something like this: `YOUR_NAME@cloudshell:~/cloudshell_open/terraform_cloud_run_sgtm (YOUR_PROJECT_ID)$`
5. Change the variables inside terraform.tfvars to suit your needs. Make sure you have created the SGTM Container already to retrieve the container config.
6. Run `terraform apply` the infrastructure will be built on GCP.

Check this [repo](https://github.com/Liscor/sgtm_cloud_run_updater) for detailed documentation about the sGTM updater Cloud Function repository.
