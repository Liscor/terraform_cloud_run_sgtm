# Project ID where terraform will build the assests in 
project_id = "seereisen-410315"

# All resources will be built in this region
region =  "europe-west3"

# Container Config string from GTM Webinterface
container_config = "aWQ9R1RNLTVCNTk1TURXJmVudj0xJmF1dGg9d0ZzZVRKbVNQclgyU0ctcUlFUkpXUQ=="

# Used for error notfication alerting 
notification_user = {
    name: "Jenny Bachmann"
    email: "jenny@mohrstade.de"
} 

# Used to name the google storage bucket
google_storage_bucket_name = "seereisen_storage_bucket"