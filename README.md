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
