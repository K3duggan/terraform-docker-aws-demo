#!/usr/bin/env bash
set -euo pipefail

mkdir -p bootstrap infra app

# ----------------------------
# bootstrap/main.tf
# ----------------------------
cat > bootstrap/main.tf <<'HCL'
terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
}

provider "aws" {
  region = var.region
}

variable "region" {
  type        = string
  description = "AWS region for the backend resources"
  default     = "us-east-1"
}

variable "s3_bucket_name" {
  type        = string
  description = "Globally-unique S3 bucket name for Terraform state (e.g., sr-devops-tfstate-<your-uniq>)"
}

variable "dynamodb_table_name" {
  type        = string
  description = "DynamoDB table name for state locking (e.g., sr-devops-tflock)"
  default     = "sr-devops-tflock"
}

resource "aws_s3_bucket" "tfstate" {
  bucket = var.s3_bucket_name
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule { apply_server_side_encryption_by_default { sse_algorithm = "AES256" } }
}

resource "aws_dynamodb_table" "tflock" {
  name         = var.dynamodb_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute { name = "LockID" type = "S" }
}

output "backend_bucket" { value = aws_s3_bucket.tfstate.bucket }
output "backend_table"  { value = aws_dynamodb_table.tflock.name }
HCL

# ----------------------------
# infra/provider.tf
# ----------------------------
cat > infra/provider.tf <<'HCL'
terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
  backend "s3" {}
}

provider "aws" {
  region = var.region
}
HCL

# ----------------------------
# infra/variables.tf
# ----------------------------
cat > infra/variables.tf <<'HCL'
variable "region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "CIDR for VPC"
  type        = string
  default     = "10.20.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR for public subnet"
  type        = string
  default     = "10.20.1.0/24"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.micro"
}

variable "allowed_ssh_cidr" {
  description = "CIDR allowed to SSH (port 22). Use your IP/32."
  type        = string
  default     = "0.0.0.0/0" # change to your_ip/32 for better security
}

variable "key_pair_name" {
  description = "Name for the EC2 key pair"
  type        = string
}

variable "public_key_path" {
  description = "Path to your local *public* SSH key (e.g., ~/.ssh/sr-devops.pub)"
  type        = string
}

variable "private_key_path" {
  description = "Path to your local *private* SSH key (e.g., ~/.ssh/sr-devops)"
  type        = string
  sensitive   = true
}

variable "app_dir_remote" {
  description = "Destination directory on the EC2 host where app files are uploaded"
  type        = string
  default     = "/home/ec2-user/app"
}
HCL

# ----------------------------
# infra/main.tf
# ----------------------------
cat > infra/main.tf <<'HCL'
# Grab a current Amazon Linux 2023 AMI via SSM Parameter (region-safe)
data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# --- Networking ---
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = "sr-devops-vpc" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "sr-devops-igw" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  map_public_ip_on_launch = true
  tags = { Name = "sr-devops-public-subnet" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "sr-devops-public-rt" }
}

resource "aws_route_table_association" "public_assoc" {
  route_table_id = aws_route_table.public.id
  subnet_id      = aws_subnet.public.id
}

# --- Security Group ---
resource "aws_security_group" "web_sg" {
  name        = "sr-devops-web-sg"
  description = "Allow HTTP from anywhere; SSH from allowed CIDR"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "SSH (restrict this)"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "sr-devops-web-sg" }
}

# --- Key Pair ---
resource "aws_key_pair" "this" {
  key_name   = var.key_pair_name
  public_key = file(var.public_key_path)
}

# --- EC2 Instance ---
resource "aws_instance" "web" {
  ami                    = data.aws_ssm_parameter.al2023_ami.value
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.web_sg.id]
  key_name               = aws_key_pair.this.key_name
  associate_public_ip_address = true

  # Install Docker via user_data (reliable)
  user_data = <<-EOF
    #!/bin/bash
    set -eux
    dnf -y update
    dnf -y install docker
    systemctl enable --now docker
    usermod -aG docker ec2-user
  EOF

  tags = {
    Name    = "sr-devops-web"
    Project = "sports-reference"
  }
}

# --- Provisioners: upload app + build/run Docker ---
# Prepare remote directory
resource "null_resource" "prepare_dir" {
  triggers = {
    instance_id = aws_instance.web.id
  }

  provisioner "remote-exec" {
    inline = ["mkdir -p ${var.app_dir_remote}"]
  }

  connection {
    type        = "ssh"
    host        = aws_instance.web.public_ip
    user        = "ec2-user"
    private_key = file(var.private_key_path)
  }
}

# Upload files
resource "null_resource" "upload_app" {
  depends_on = [null_resource.prepare_dir]

  triggers = {
    instance_id = aws_instance.web.id
  }

  provisioner "file" {
    source      = "${path.module}/../app/Dockerfile"
    destination = "${var.app_dir_remote}/Dockerfile"
  }

  provisioner "file" {
    source      = "${path.module}/../app/app.js"
    destination = "${var.app_dir_remote}/app.js"
  }

  provisioner "file" {
    source      = "${path.module}/../app/package.json"
    destination = "${var.app_dir_remote}/package.json"
  }

  connection {
    type        = "ssh"
    host        = aws_instance.web.public_ip
    user        = "ec2-user"
    private_key = file(var.private_key_path)
  }
}

# Build and run the container
resource "null_resource" "docker_build_run" {
  depends_on = [null_resource.upload_app]

  triggers = {
    instance_id = aws_instance.web.id
  }

  provisioner "remote-exec" {
    inline = [
      "cd ${var.app_dir_remote}",
      "sudo docker build -t hello-world-node .",
      "sudo docker rm -f hello || true",
      "sudo docker run -d --name hello -p 80:80 hello-world-node"
    ]
  }

  connection {
    type        = "ssh"
    host        = aws_instance.web.public_ip
    user        = "ec2-user"
    private_key = file(var.private_key_path)
  }
}
HCL

# ----------------------------
# infra/outputs.tf
# ----------------------------
cat > infra/outputs.tf <<'HCL'
output "public_ip" {
  description = "Public IP of the EC2 instance"
  value       = aws_instance.web.public_ip
}

output "http_url" {
  description = "Convenience URL"
  value       = "http://${aws_instance.web.public_ip}/"
}
HCL

# ----------------------------
# infra/terraform.tfvars.example
# ----------------------------
cat > infra/terraform.tfvars.example <<'HCL'
region            = "us-east-1"
key_pair_name     = "sr-devops-key"
public_key_path   = "~/.ssh/sr-devops.pub"
private_key_path  = "~/.ssh/sr-devops"
allowed_ssh_cidr  = "YOUR.PUBLIC.IP.ADDR/32" # replace!
HCL

# ----------------------------
# app/Dockerfile
# ----------------------------
cat > app/Dockerfile <<'DOCKER'
FROM node:24-alpine
WORKDIR /usr/src/app
COPY package.json ./
COPY app.js ./
RUN npm install --production
EXPOSE 80
CMD ["npm", "start"]
DOCKER

# ----------------------------
# app/app.js
# ----------------------------
cat > app/app.js <<'JS'
const http = require('http');
const hostname = '0.0.0.0';
const port = 80;
const server = http.createServer((req, res) => {
  res.statusCode = 200;
  res.setHeader('Content-Type', 'text/html');
  res.end('<h1>Hello, World!</h1>');
});
server.listen(port, hostname, () => {
  console.log(\`Server running at http://\${hostname}:\${port}/\`);
});
JS

# ----------------------------
# app/package.json
# ----------------------------
cat > app/package.json <<'JSON'
{
  "name": "hello-world",
  "version": "1.0.0",
  "description": "Simple Hello World app",
  "main": "app.js",
  "scripts": {
    "start": "node app.js"
  },
  "dependencies": {}
}
JSON

# ----------------------------
# .gitignore
# ----------------------------
cat > .gitignore <<'GIT'
# Node.js
node_modules/
npm-debug.log
yarn-error.log

# Docker
*.tar
*.log

# Terraform
*.tfstate
*.tfstate.*
crash.log
crash.*.log
override.tf
override.tf.json
*_override.tf
*_override.tf.json
.terraform/
.terraform.lock.hcl

# AWS credentials (never commit!)
*.pem
*.key
*.pub
*.crt

# OS / Editor junk
.DS_Store
Thumbs.db
*.swp
*.swo
.idea/
.vscode/
*.bak

# App build artifacts
dist/
build/
GIT

# ----------------------------
# README.md (minimal)
# ----------------------------
cat > README.md <<'MD'
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

