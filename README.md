# Terraform Cloud Run Deployment - Serverside Google Tag Manager
This Terraform script deploys the serverside Google Tag Manager on Cloud Run within the Google Cloud Platform.
## Features
- Startup- and Liveness Probe
- Uptime Check with Notifications

Planned
- Autoupdate for new Docker Image versions
## Getting Started
1. Create a new service account for terraform with the primitive role "owner" within the desired GCP project 
2. Create and download the JSON key file for the service account and copy it to the directory of this respository
3. Activate the `cloudresourcemanager.googleapis.com` and `serviceusage.googleapis.com` API within Google Cloud Console
4. Clone this repository and make sure you have installed [Terraform](https://developer.hashicorp.com/terraform/tutorials/gcp-get-started/install-cli).
5. Change the variables inside terraform.tfvars.example to suit your needs and rename the file to terraform.tfvars.
6. Run `terraform init` to initialize the repository and `terraform apply` the infrastructure will be built on GCP