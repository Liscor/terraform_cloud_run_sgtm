# Serverside Google Tag Manager - Terraform Cloud Run Deployment

This Terraform script deploys the serverside Google Tag Manager on Cloud Run within the Google Cloud Platform with various extra features like automated updates and an alerting policy.

## Features

- Uptime Check with Notifications - You will be notified if there is an outage of your SGTM services
- Docker Image Auto Updates - The SGTM Docker image will be updated automatically once per week (default)
- Log Exculusion - Logs with the serverity default or notice will be excluded to reduce costs
- Optional basic load balancer setup enabled via setting use_load_balancer variable to true.
- The Load balancer contains the Geolocation headers described [here](https://developers.google.com/tag-platform/tag-manager/server-side/enable-region-specific-settings) and the additonal ones neccesary for sending geolocation data to GA4 described [here](https://www.simoahava.com/gtm-tips/utilize-app-engine-headers-server-side-tagging/) All possible headers are listed [here](https://cloud.google.com/load-balancing/docs/https/custom-headers)

## Getting Started

### Quick Start

1. Clone this repository and make sure you have installed [Terraform](https://developer.hashicorp.com/terraform/tutorials/gcp-get-started/install-cli).
2. Authenticate with Application Default Credentials - Setup [Application Default Credentials](https://cloud.google.com/docs/authentication/provide-credentials-adc#local-user-cred).
3. Change the variables inside terraform.tfvars.example to suit your needs and rename the file to terraform.tfvars. Make sure you have created the SGTM Container already to retrieve the container config.
4. Run `terraform init` to initialize the repository and `terraform apply` the infrastructure will be built on GCP

Check this [repo](https://github.com/Liscor/sgtm_cloud_run_updater) for detailed documentation about the sGTM updater Cloud Function repository.
