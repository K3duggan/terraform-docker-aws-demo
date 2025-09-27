<<<<<<< Updated upstream
# terraform-docker-aws-demo
Sample project demonstrating AWS infrastructure with Terraform and Docker, deploying a simple Node.js app to EC2.

This deploys a tiny Node.js web server in Docker on an EC2 instance inside a VPC (public subnet + IGW + route). Terraform uses **remote state** (S3 backend with DynamoDB locking) and uploads/builds the Dockerized app on the instance.

## Prereqs

- Terraform >= 1.6
- AWS account + credentials with perms for: S3, DynamoDB, EC2, VPC, IAM key pairs
- An SSH key pair on your machine (e.g., `~/.ssh/id_rsa` + `~/.ssh/id_rsa.pub`)
- Your public IPv4 to restrict SSH (find with `curl ifconfig.me`)

---

## 0) Bootstrap remote backend (one-time)

Terraform cannot use an S3 backend until the bucket & lock table exist.

```bash
cd bootstrap
terraform init
terraform apply -auto-approve \
  -var="s3_bucket_name=sr-devops-tfstate-<your-unique-suffix>" \
  -var="region=us-east-1" \
  -var="dynamodb_table_name=sr-devops-tflock"
=======
# Terraform + Docker + AWS Demo

Deploys a tiny Node.js “Hello, World!” app in a Docker container on an EC2 instance inside a VPC using Terraform.

## 🔎 GRADER MODE (copy/paste)
```bash
# 0) Bootstrap backend
cd bootstrap
terraform init
terraform apply -auto-approve \
  -var="s3_bucket_name=sr-devops-tfstate-<uniq>" \
  -var="region=us-east-1" \
  -var="dynamodb_table_name=sr-devops-tflock"

# 1) Main stack
cd ../infra
cp terraform.tfvars.example terraform.tfvars
# EDIT terraform.tfvars: allowed_ssh_cidr="<YOUR.IP>/32", ssh key paths
terraform init \
  -backend-config="bucket=sr-devops-tfstate-<uniq>" \
  -backend-config="key=infra/terraform.tfstate" \
  -backend-config="region=us-east-1" \
  -backend-config="dynamodb_table=sr-devops-tflock"
terraform apply -auto-approve

# 2) Test
terraform output http_url

# 3) Destroy
terraform destroy -auto-approve
cd ../bootstrap && terraform destroy -auto-approve

>>>>>>> Stashed changes
