# Name prefix for the resources
name = "sgtm"

# Project ID where Terraform will build the assets in
project_id = "PROJECT_ID"

# The project name
project_name = "PROJECT_NAME"

# Container config string from GTM web interface
container_config = "SGTM_CONTAINER_CONFIG"

# Used for error notification alerting
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

# Used to name the Google Storage bucket. Must be globally unique.
google_storage_bucket_name = "sgtm_bucket_name"

# Used to add custom domain names to the load balancer
# Separate multiple domain names with a comma
# e.g. domain_names = ["sgtm.example.com", "sgtm2.example.com"]
domain_names = ["sgtm.example.com"]

# Do you want to have a load balancer or not
use_load_balancer = false

# Deletion protection
deletion_protection = false

# ---------------------------------------------------------------------------
# MIG / VM backend (optional, cost optimization). All off by default.
# ---------------------------------------------------------------------------
# use_mig               = true            # deploy the MIG backend (requires use_load_balancer = true)
# mig_traffic_weight    = 0               # 0 = all Cloud Run (test phase); ramp 10 -> 50 -> 100
# mig_machine_type      = "e2-standard-2"
# mig_primary_size      = 1               # set to match committed-use baseline vCPUs
# max_rate_per_instance = 50              # REQUIRED when use_mig; pin via load test
# mig_overflow_max      = 3
# overflow_spot         = true            # false = on-demand overflow (zero data loss)
# mig_network           = "default"
# mig_subnetwork        = "default"
# mig_scheduled_refresh = false           # enabling also grants the SA roles/compute.instanceAdmin.v1