# Terraform + Docker + AWS Demo

Deploys a tiny Node.js “Hello, World!” web app in a Docker container on an EC2 instance inside a VPC using **Terraform**. This repo is designed for learning and demonstration: clean, reproducible, and minimal.

---

## What this repo does

- **VPC & Networking**
  - VPC: `10.20.0.0/16`
  - Public subnet: `10.20.1.0/24`
  - Internet Gateway + Route to `0.0.0.0/0`
- **Security**
  - Security Group: **HTTP (80) from anywhere**
  - Security Group: **SSH (22) from <Your IP>/32**
- **Compute**
  - EC2 (Amazon Linux 2023, `t3.micro`, public IP)
  - Docker installed (via `user_data`) and validated (provisioner)
  - App deployed via provisioners: files uploaded → Docker image built → container run on port 80
- **State management**
  - Terraform **remote state** in **S3** with **DynamoDB locking** (bootstrap step)

---

## Repo layout



bootstrap/ # one-time: S3 bucket + DynamoDB lock table for Terraform backend
infra/ # VPC, SG, EC2, provisioners, outputs
app/ # Dockerfile, app.js, package.json (Hello, World!)


---

## Prerequisites

- macOS with:
  - Terraform >= 1.6, AWS CLI, Git
  - (optional) Docker Desktop (not required to deploy—Docker runs on EC2)
- AWS account + IAM user **access key/secret** (not root), region (e.g., `us-east-1`)
- SSH keys:
  - **GitHub key** (e.g., `~/.ssh/id_ed25519`) for repo access
  - **EC2 key** (e.g., `~/.ssh/sr-devops` + `sr-devops.pub`) for SSH/provisioners

> 💸 **Cost note:** Running an EC2 instance can incur charges (See AWS guides for details). Destroy when done.

---

## Quick start

```bash
# 0) Configure AWS locally (once)
aws configure --profile devops-assessment
export AWS_PROFILE=devops-assessment
export AWS_DEFAULT_REGION=us-east-1

# 1) Bootstrap Terraform remote state (one-time)
cd bootstrap
terraform init
terraform apply -auto-approve \
  -var="s3_bucket_name=sr-devops-tfstate-<Your name uniq>" \
  -var="region=us-east-1" \
  -var="dynamodb_table_name=sr-devops-tflock"

# 2) Configure and deploy the infrastructure + app
cd ../infra
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars:
#   allowed_ssh_cidr = "<YOUR.PUBLIC.IP>/32"   # curl -s https://checkip.amazonaws.com
#   key_pair_name    = "sr-devops-key"
#   public_key_path  = "/Users/<you>/.ssh/sr-devops.pub"    # use ABSOLUTE paths
#   private_key_path = "/Users/<you>/.ssh/sr-devops"

terraform init \
  -backend-config="bucket=sr-devops-tfstate-<uniq>" \
  -backend-config="key=infra/terraform.tfstate" \
  -backend-config="region=us-east-1" \
  -backend-config="dynamodb_table=sr-devops-tflock"

terraform apply -auto-approve

# 3) Access the app
terraform output http_url
# open the printed URL in your browser → shows "Hello, World!"

# 4) Clean up when done
terraform destroy -auto-approve
cd ../bootstrap && terraform destroy -auto-approve

Step-by-step (with context)
1) AWS CLI profile
aws configure --profile devops-assessment
export AWS_PROFILE=devops-assessment
export AWS_DEFAULT_REGION=us-east-1
aws sts get-caller-identity   # sanity check

2) Create EC2 SSH key (if you don’t have one)
ssh-keygen -t ed25519 -f ~/.ssh/sr-devops -C "sr-devops-key"
chmod 600 ~/.ssh/sr-devops

3) Bootstrap remote state

Creates an S3 bucket (versioned, SSE enabled) + DynamoDB table for Terraform locking

Run from bootstrap/ (see “Quick start”)

4) Configure infra/terraform.tfvars

Use ABSOLUTE paths (Terraform’s file() doesn’t expand ~, but code includes pathexpand() as a convenience)

Lock SSH to your IP /32 for security

Example:

region            = "us-east-1"
key_pair_name     = "sr-devops-key"
public_key_path   = "/Users/youruser/.ssh/sr-devops.pub"
private_key_path  = "/Users/youruser/.ssh/sr-devops"
allowed_ssh_cidr  = "<myip>/32"

5) Deploy

Run terraform init with your backend config, then terraform apply

Provisioners will:

Create dir on host

Upload app/ files

Wait for Docker to be ready (race-proof)

Build and run the container mapping -p 80:80

6) Access
terraform output http_url
open "$(terraform output -raw http_url)"   # macOS shortcut

What’s inside (files of interest)

bootstrap/main.tf

S3 backend bucket (versioning + SSE)

DynamoDB lock table

infra/main.tf

VPC, subnet, IGW, route table

Security Group (HTTP 80 world; SSH 22 from myip /32)

EC2 instance (Amazon Linux 2023 via SSM)

user_data installs Docker; provisioners upload app & run container

wait_for_docker ensures Docker is ready before build/run

app/Dockerfile

node:24-alpine, installs dependencies, exposes 80, starts app

app/app.js

Minimal HTTP server on 0.0.0.0:80

app/package.json

"start": "node app.js"

Public accessibility

Yes, it’s public on port 80:

Security group allows HTTP from 0.0.0.0/0

Instance has a public IP

Route to IGW is configured

Container maps -p 80:80

Anyone with the http_url output can see the page.

Troubleshooting

“No valid credential sources found”

Configure and export your profile:

aws configure --profile devops-assessment
export AWS_PROFILE=devops-assessment


S3 bucket name invalid

Use only lowercase letters/numbers/hyphens; must be globally unique.
Example: sr-devops-tfstate-<your-initials>-<timestamp>

Unsupported block type: connection

Remove any top-level connection {} blocks; only allowed inside resources.

Invalid value for "path" / ~ not expanding

Use absolute paths in terraform.tfvars, or ensure code uses pathexpand() around paths.

Docker “command not found” during build

That’s a timing/race:

This repo includes a wait_for_docker step to prevent it.

If you hit it once, re-apply or SSH and sudo dnf -y install docker; sudo systemctl enable --now docker.

SSH/provisioner timeout

Confirm allowed_ssh_cidr matches your current IP/32

Confirm keys/paths are correct and private key perms are 600

HTTP not reachable

Confirm:

Security Group inbound 80 is open

Instance has a public IP

Route table points 0.0.0.0/0 to IGW

Container is running: sudo docker ps

Clean up
cd infra && terraform destroy -auto-approve
cd ../bootstrap && terraform destroy -auto-approve

Notes & Rationale

AMI via SSM → region-safe, no hard-coded AMI IDs

Remote state (S3 + DynamoDB) → collaboration-safe, standard practice

Provisioners → used here for a simple single-instance demo

Wait-for-Docker → avoids race conditions during first boot

Security → SSH is locked to myip /32; HTTP open for demo

Future improvements (if need to extend)

Replace provisioners with user_data-only or a config mgmt tool

Push image to ECR; run via ECS or EKS

Front with an ALB; use Auto Scaling; put instance in private subnets

CI/CD pipeline (GitHub Actions) to apply Terraform automatically

Git basics (push your changes)
git status
git add -A
git commit -m "Initial infra + app + docs"
git push -u origin main
