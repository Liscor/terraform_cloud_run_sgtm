# Name prefix for the resources
name = "sgtm"

# Project ID where terraform will build the assests in
project_id = "PROJECT_ID"

# The project name
project_name = "PROJECT_NAME"

# Container Config string from GTM Webinterface
container_config = "SGTM_CONTAINER_CONFIG"

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

# Used to name the google storage bucket. Must be globally unique.
google_storage_bucket_name = "sgtm_bucket_name"

domain_name = "SGTM.EXAMPLE.COM"

# Do you want to have a load balancer or not
use_load_balancer = false

# Deletion protection
deletion_protection=false