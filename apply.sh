#! /bin/bash

#Initialize Terraform
terraform init

#Initialize GCloud
gcloud auth application-default set-quota-project $(echo "var.project_id" | terraform console | tr -d '\n' | sed 's/^.//; s/.$//')
gcloud config set project $(echo "var.project_id" | terraform console | tr -d '\n' | sed 's/^.//; s/.$//')
gcloud services enable cloudresourcemanager.googleapis.com

#Apply Changes
terraform apply