# Name prefix for the resources
name = "ssgtm"

# Project ID where terraform will build the assests in
project_id = "PROJECT_ID"

# The project name
project_name = "PROJECT_NAME"

# All resources will be built in this region
region =  "REGION"

# Container Config string from GTM Webinterface
container_config = "SGTM_CONTAINER_CONFIG"

# The names for the SGTM Cloud Run services
service_name_preview = "sgtm-preview"
service_name_production = "sgtm-production"

# Controls the maximum and minimum instances for Cloud Run service running the production SGTM
min_instance_count = 0
max_instance_count = 1
cpu_boost = true

# Number of instances after which instance count alert will be triggered. Best practise is to set this number to 80% of the maximum number of production instances
alert_instance_count = 8

# DONT Change this - Log filter to trigger alerts when SGTM got updated
cloud_function_update_filter = "resource.type=\"cloud_function\" \nAND textPayload=~\"Versions are different: Deploying a new revision\""

# Update interval for the Cloud Function updating the SGTM Image in unix-cron job format - Default everyday at 8:00 am UTC
update_interval = "0 8 * * *"

# The filter to define which logs will be excluded
cloud_run_exclusion_filter = "resource.type=\"cloud_run_revision\" AND severity = \"INFO\" OR severity =\"DEFAULT\""

# Used for error notfication alerting
notification_users = [
  {
    name  = "USER_NAME_1",
    email = "USER_EMAIL_1"
  },
  {
    name  = "USER_NAME_2",
    email = "USER_EMAIL_2"
  }
  # ....
  # Add more users if needed
]

# Used to name the google storage bucket
google_storage_bucket_name = "SSGTM_BUCKET_NAME"

domain_name = "SSGTM.EXAMPLE.COM"

# Do you want to have a load balancer or not
use_load_balancer = false

# Deletion protection
deletion_protection=false