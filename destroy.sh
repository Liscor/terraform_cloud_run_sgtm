#Initialize Terraform
terraform init

#Initialize GCloud
gcloud auth application-default set-quota-project $(echo "var.project_id" | terraform console | tr -d '\n' | sed 's/^.//; s/.$//')
gcloud config set project $(echo "var.project_id" | terraform console | tr -d '\n' | sed 's/^.//; s/.$//')

#Check for .tfstate Files
if [ -d "$(echo "var.project_id" | terraform console | tr -d '\n' | sed 's/^.//; s/.$//')" ]; then
    cp -R $(echo "var.project_id" | terraform console | tr -d '\n' | sed 's/^.//; s/.$//')/terraform.tfstate .
    cp -R $(echo "var.project_id" | terraform console | tr -d '\n' | sed 's/^.//; s/.$//')/terraform.tfstate.backup .
    rm -r $(echo "var.project_id" | terraform console | tr -d '\n' | sed 's/^.//; s/.$//')
fi

#Destroy
terraform destroy