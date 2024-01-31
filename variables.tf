variable "project_id" {
  description = "The project ID in which the stack is being deployed"
  type        = string
}

variable "region" {
  description = "The name of the region to deploy within"
  type        = string
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

variable "notification_user" {
  description = "The name and e-mail address used in the notification channel setup"
  type        = object({
    name  = string
    email = string
  })
}

variable "google_storage_bucket_name" {
    description = "The unique name of the google storage bucket"
    type = string
}