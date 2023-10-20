# Terraform Cloud Run Deployment - Serverside Google Tag Manager
This Terraform script deploys the serverside Google Tag Manager on Cloud Run within the Google Cloud Platform.
## Features
- Startup- and Liveness Probe
- Uptime Check with Notifications
- Auto updates for serverside GTM Docker Images on Cloud Run via Cloud Function and Cloud Scheduler

## Getting Started
1. Clone this repository and make sure you have installed [Terraform](https://developer.hashicorp.com/terraform/tutorials/gcp-get-started/install-cli).
2. Change the variables inside terraform.tfvars.example to suit your needs and rename the file to terraform.tfvars.
3. Run `terraform init` to initialize the repository and `terraform apply` the infrastructure will be built on GCP