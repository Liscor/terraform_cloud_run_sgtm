# Project ID where terraform will build the assests in 
project_id = "moritz-test-projekt"

# All resources will be built in this region
region =  "europe-west3"

# Container Config string from GTM Webinterface
container_config = "aWQ9R1RNLUtOTEtHMlA4JmVudj0xJmF1dGg9T2IzamtQdl9mNkhRS2toR0F3OWtUQQ=="

#Controls the maximum instances for Cloud Run service running the production SGTM
maximum_instance_count = 5

cloud_run_logs_filter = ""

# Used for error notfication alerting 
notification_user = {
    name: "Moritz Bauer"
    email: "moritz@mohrstade.de"
} 

# Used to name the google storage bucket
google_storage_bucket_name = "moritz-test-projekt-bucket"