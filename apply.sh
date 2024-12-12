#! /bin/bash

#Initialize Terraform
terraform init

#Initialize GCloud
gcloud auth application-default set-quota-project $(echo "var.project_id" | terraform console | tr -d '\n' | sed 's/^.//; s/.$//')
gcloud config set project $(echo "var.project_id" | terraform console | tr -d '\n' | sed 's/^.//; s/.$//')
gcloud services enable cloudresourcemanager.googleapis.com

#
if [ -d "$(echo "var.project_id" | terraform console | tr -d '\n' | sed 's/^.//; s/.$//')" ]; 
then
    cp -R $(echo "var.project_id" | terraform console | tr -d '\n' | sed 's/^.//; s/.$//')/terraform.tfstate .
    cp -R $(echo "var.project_id" | terraform console | tr -d '\n' | sed 's/^.//; s/.$//')/terraform.tfstate.backup .
else
    mkdir $(echo "var.project_id" | terraform console | tr -d '\n' | sed 's/^.//; s/.$//')
fi

#Apply Changes
terraform apply

#Move .tfstate Files do a dedicated Folder
cp -R terraform.tfstate $(echo "var.project_id" | terraform console | tr -d '\n' | sed 's/^.//; s/.$//')
cp -R terraform.tfstate.backup $(echo "var.project_id" | terraform console | tr -d '\n' | sed 's/^.//; s/.$//')
cp -R terraform.tfvars $(echo "var.project_id" | terraform console | tr -d '\n' | sed 's/^.//; s/.$//')