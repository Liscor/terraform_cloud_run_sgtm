variable "project_id" {
  description = "The project ID in which the stack is being deployed"
  type        = string
}

variable "project_name" {
  description = "The name of the project"
  type        = string
}

variable "region" {
  description = "The name of the region to deploy within"
  type        = string
  default     = "europe-west1"
}

variable "organization_id" {
  description = "The organization ID for your project"
  type        = string
  default     = null # Set null if not part of an organization
}

variable "container_config" {
  description = "The container configuration string obtained from the Google Tag Manager Webinterface"
  type        = string
}

variable "service_name_production" {
  description = "The name of the SGTM production service in Cloud Run."
  type        = string
  default     = "sgtm-production"
}

variable "service_name_preview" {
  description = "The name of the SGTM preview service in Cloud Run."
  type        = string
  default     = "sgtm-preview"
}

variable "min_instance_count" {
  description = "The minimum instances the Cloud Run service for production SGTM should maintain."
  type        = number
  default     = 0
}

variable "max_instance_count" {
  description = "The maximum instances the Cloud Run service for production SGTM can create."
  type        = number
  default     = 10
}

variable "alert_instance_count" {
  description = "Number of instances after which instance count alert will be triggered."
  type        = number
  default     = 8
}

variable "cpu_boost" {
  description = "Activate CPU boost to allocate more CPUs for instances starting up."
  type        = bool
  default     = false
}

variable "cloud_function_update_filter" {
  description = "The Cloud function logs when the the Cloud Run SGTM instance gets updated."
  type        = string
  default     = "resource.type=\"cloud_function\" \nAND textPayload=~\"Versions are different: Deploying a new revision\""
}

variable "update_interval" {
  description = "Update interval for the Cloud Function updating the SGTM Image in unix-cron job format - Default everyday at 8:00 am UTC"
  type        = string
  default     = "0 8 * * *"
}

variable "cloud_run_exclusion_filter" {
  description = "The Cloud Run logs which will be exclude from the _default bucket."
  type        = string
  default     = "resource.type=\"cloud_run_revision\" AND (resource.labels.service_name=\"sgtm-production\" OR resource.labels.service_name=\"sgtm-preview\") AND (severity=\"INFO\" OR severity=\"DEFAULT\")"
}

variable "notification_users" {
  description = "List of users for notification"
  type = list(object({
    name  = string
    email = string
  }))
}

variable "google_storage_bucket_name" {
  description = "The suffix for the google storage bucket name. Will be prefixed with project_id to ensure global uniqueness (final name: <project_id>-<this_value>)"
  type        = string
}

variable "domain_names" {
  description = "Domain names for the load balancer. Required when use_load_balancer is true."
  type        = list(string)
  default     = null
}

variable "name" {
  description = "The name of the stack"
  type        = string
}

variable "use_load_balancer" {
  description = "Whether to use a load balancer"
  type        = bool
  default     = false
}

variable "deletion_protection" {
  description = "Whether to enable deletion protection"
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# MIG / VM backend (all default to "no change" so existing deploys are untouched)
#
# One regional, multi-zone Managed Instance Group runs the sGTM container behind
# the load balancer as a lower-cost alternative to Cloud Run. Each VM packs
# mig_containers_per_vm containers (one per serving core) behind an in-VM nginx.
# ---------------------------------------------------------------------------

variable "use_mig" {
  description = "Master switch: deploy the regional GCE MIG/VM backend behind the load balancer. Requires the load balancer to be enabled."
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

variable "mig_machine_type" {
  description = "Machine type for the MIG VMs. Dedicated-core highcpu recommended; (cores - 1) serve containers, 1 core is reserved for the OS + nginx."
  type        = string
  default     = "c2d-highcpu-4"
}

variable "mig_containers_per_vm" {
  description = "sGTM containers per VM (one per serving core; one core reserved for the OS + nginx fan-out). Container ports start at 8081."
  type        = number
  default     = 3
}

variable "mig_min_replicas" {
  description = "Autoscaler floor for the MIG (always-warm, multi-zone resilience baseline)."
  type        = number
  default     = 2
}

variable "mig_max_replicas" {
  description = "Autoscaler ceiling for the MIG."
  type        = number
  default     = 4
}

variable "mig_prewarm_min_replicas" {
  description = "Scheduled floor applied before the daily peak so warm VMs exist before the ramp (no scale-up lag)."
  type        = number
  default     = 3
}

variable "mig_prewarm_cron" {
  description = "Cron (in mig_time_zone) marking the start of the pre-peak warm window."
  type        = string
  default     = "30 5 * * *"
}

variable "mig_prewarm_duration_sec" {
  description = "How long the scheduled prewarm floor is held, from mig_prewarm_cron. 25200 = 7h."
  type        = number
  default     = 25200
}

variable "mig_time_zone" {
  description = "IANA time zone for the MIG scaling schedule and optional refresh job."
  type        = string
  default     = "Europe/Berlin"
}

variable "max_rate_per_instance" {
  description = "Requests/sec per instance that defines a backend as 'full' (LB RATE balancing + autoscale trigger). Pin this via a load test. Required when use_mig is true."
  type        = number
  default     = null
}

variable "mig_network" {
  description = "VPC network for the MIG VMs."
  type        = string
  default     = "default"
}

variable "mig_subnetwork" {
  description = "Subnetwork (in var.region) for the MIG VMs. Used to scope Cloud NAT."
  type        = string
  default     = "default"
}

variable "mig_scheduled_refresh" {
  description = "If true, a Cloud Scheduler job periodically rolling-restarts the MIG so instances re-pull the :stable image. Enabling also grants the service account roles/compute.instanceAdmin.v1."
  type        = bool
  default     = false
}
