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
  default     = null  # Set null if not part of an organization
}

variable "container_config" {
    description = "The container configuration string obtained from the Google Tag Manager Webinterface"
    type = string
}

variable "service_name_production" {
    description = "The name of the SGTM production service in Cloud Run."
    type = string
    default = "sgtm-production"
}

variable "service_name_preview" {
    description = "The name of the SGTM preview service in Cloud Run."
    type = string
    default = "sgtm-preview"
}

variable "min_instance_count" {
  description = "The maximum instances the Cloud Run service for production SGTM can create."
  type = number
  default = 0
}

variable "max_instance_count" {
  description = "The maximum instances the Cloud Run service for production SGTM can create."
  type = number
  default = 10
}

variable "alert_instance_count" {
  description = "Number of instances after which instance count alert will be triggered."
  type = number
  default = 8
}

variable "cpu_boost" {
  description = "Activate CPU boost to allocate more CPUs for instances starting up."
  type = bool
  default = false
}

variable "cloud_function_update_filter" {
  description = "The Cloud function logs when the the Cloud Run SGTM instance gets updated."
  type = string
  default = "resource.type=\"cloud_function\" \nAND textPayload=~\"Versions are different: Deploying a new revision\""
}

variable "update_interval" {
  description = "Update interval for the Cloud Function updating the SGTM Image in unix-cron job format - Default everyday at 8:00 am UTC"
  type = string
  default = "0 8 * * *"
}

variable "cloud_run_exclusion_filter" {
  description = "The Cloud Run logs which will be exclude from the _default bucket."
  type = string
  default = "resource.type=\"cloud_run_revision\" AND severity = \"INFO\" OR severity =\"DEFAULT\""
}

variable "notification_users" {
  description = "List of users for notification"
  type = list(object({
    name  = string
    email = string
  }))
}

variable "google_storage_bucket_name" {
    description = "The unique name of the google storage bucket"
    type = string
}

variable "domain_names" {
  description = "Domain names for the load balancer."
  type        = list(string)
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