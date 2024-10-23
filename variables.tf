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
}

variable "service_name_preview" {
    description = "The name of the SGTM preview service in Cloud Run."
    type = string
}

variable "min_instance_count" {
  description = "The maximum instances the Cloud Run service for production SGTM can create."
  type = number
}

variable "max_instance_count" {
  description = "The maximum instances the Cloud Run service for production SGTM can create."
  type = number
}

variable "alert_instance_count" {
  description = "Number of instances after which instance count alert will be triggered."
  type = number
}

variable "cpu_boost" {
  description = "Activate CPU boost to allocate more CPUs for instances starting up."
  type = bool
}

variable "cloud_function_update_filter" {
  description = "The Cloud function logs when the the Cloud Run SGTM instance gets updated."
  type = string
}

variable "update_interval" {
  description = "Update interval for the Cloud Function updating the SGTM Image in unix-cron job format - Default everyday at 8:00 am UTC"
  type = string
}

variable "cloud_run_exclusion_filter" {
  description = "The Cloud Run logs which will be exclude from the _default bucket."
  type = string
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

variable "domain_name" {
  description = "Domain name for the load balancer."
  type        = string
  default     = ""
}

variable "name" {
  description = "The name of the stack"
  type        = string
}

variable "use_load_balancer" {
  description = "Whether to use a load balancer"
  type        = bool
  default     = true
}