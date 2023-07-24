variable "project_id" {
  description = "The project ID in which the stack is being deployed"
  type        = string
}

variable "service_account_file" {
  description = "The path to the service account file for deployment"
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

variable "notification_user" {
  description = "The name and e-mail address used in the notification channel setup"
  type        = object({
    name  = string
    email = string
  })
}