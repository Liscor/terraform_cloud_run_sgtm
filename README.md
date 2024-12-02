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

### Run in Google Cloud Shell
1. Use This link to the [Cloud Shell](https://console.cloud.google.com/cloudshell/open?git_repo=https://github.com/Liscor/terraform_cloud_run_sgtm&page=editor&open_in_editor=terraform.tfvars)
   1. If you want the Cloud Shell Instance to not be persistant use this link: [non-persistant Cloud Shell](https://console.cloud.google.com/cloudshell/open?git_repo=https://github.com/Liscor/terraform_cloud_run_sgtm&page=editor&open_in_editor=terraform.tfvars&ephemeral=true).
2. Trust the Repo and Confirm when prompted.
3. Wait till Cloud Shell has completed loading. You should see the terraform.tfvars File.
4. Run `bash run_this.sh` 
   1. Click Authorize when asked to Authorize Cloud Shell.
   2. Hit `1` to initialize with new settings
   3. Hit `1` to sign in or sign in manually to the Google Account you want to use.
   4. Enter the project ID, create a new project or choose from the list of projects the one you want to use.
   5. Hit `y` to proceed. This Cloud Shell Instance is Ephemeral, it destroys itself after 20 Minutes of inactivity.
   6. Click the Link that is shown, choose the desired Google Account, sign in to Google Auth Library and grant access.
   7. Click the `Copy` Button and paste to Google Cloud Shell.
   8. You should now see something like this: `YOUR_NAME@cloudshell:~/cloudshell_open/terraform_cloud_run_sgtm (YOUR_PROJECT_ID)$`
5. Change the variables inside terraform.tfvars to suit your needs. Make sure you have created the SGTM Container already to retrieve the container config.
6. Run `terraform apply` the infrastructure will be built on GCP.

Check this [repo](https://github.com/Liscor/sgtm_cloud_run_updater) for detailed documentation about the sGTM updater Cloud Function repository.
