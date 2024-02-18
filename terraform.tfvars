# Project ID where terraform will build the assests in 
project_id = "YOUR_GCP_RPOJECT_ID"

# All resources will be built in this region
region =  "europe-west3"

# Container Config string from GTM Webinterface
container_config = "SGTM_CONTAINER_CONFIG"

# The names for the SGTM Cloud Run services
service_name_preview = "sgtm-preview"
service_name_production = "sgtm-production"

# Controls the maximum and minimum instances for Cloud Run service running the production SGTM
min_instance_count = 0
max_instance_count = 1
cpu_boost = true

# DONT Change this - Log filter to trigger alerts when SGTM got updated
cloud_function_update_filter = "resource.type=\"cloud_function\" \nAND textPayload=~\"Versions are different: Deploying a new revision\""

# Update interval for the Cloud Function updating the SGTM Image in unix-cron job format - Default everyday at 8:00 am UTC
update_interval = "0 8 * * *"

# The filter to define which logs will be excluded
cloud_run_exclusion_filter = "resource.type=\"cloud_run_revision\" AND severity = \"INFO\" OR severity =\"DEFAULT\""

# Used for error notfication alerting 
notification_user = {
    name: "YOUR_NAME"
    email: "YOUR_EMAIL"
} 

# Used to name the google storage bucket
google_storage_bucket_name = "RANDOM_STRING"