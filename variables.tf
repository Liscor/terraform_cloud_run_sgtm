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

variable "mig_machine_type" {
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
