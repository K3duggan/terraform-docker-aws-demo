#!/usr/bin/env bash
set -euxo pipefail

mkdir -p bootstrap infra app

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
provider "aws" { region = var.region }
variable "region" { type = string, description = "Region", default = "us-east-1" }
variable "s3_bucket_name" { type = string, description = "S3 bucket for TF state" }
variable "dynamodb_table_name" { type = string, description = "Lock table", default = "sr-devops-tflock" }
resource "aws_s3_bucket" "tfstate" { bucket = var.s3_bucket_name }
resource "aws_s3_bucket_versioning" "tfstate" { bucket = aws_s3_bucket.tfstate.id versioning_configuration { status = "Enabled" } }
resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" { bucket = aws_s3_bucket.tfstate.id rule { apply_server_side_encryption_by_default { sse_algorithm = "AES256" } } }
resource "aws_dynamodb_table" "tflock" { name = var.dynamodb_table_name billing_mode = "PAY_PER_REQUEST" hash_key = "LockID" attribute { name = "LockID" type = "S" } }
output "backend_bucket" { value = aws_s3_bucket.tfstate.bucket }
output "backend_table"  { value = aws_dynamodb_table.tflock.name }
HCL

cat > infra/provider.tf <<'HCL'
terraform {
  required_version = ">= 1.6.0"
  required_providers { aws = { source = "hashicorp/aws" version = "~> 5.60" } }
  backend "s3" {}
}
provider "aws" { region = var.region }
HCL

cat > infra/variables.tf <<'HCL'
variable "region"            { type = string  default = "us-east-1" }
variable "vpc_cidr"          { type = string  default = "10.20.0.0/16" }
variable "public_subnet_cidr"{ type = string  default = "10.20.1.0/24" }
variable "instance_type"     { type = string  default = "t3.micro" }
variable "allowed_ssh_cidr"  { type = string  default = "0.0.0.0/0" }
variable "key_pair_name"     { type = string }
variable "public_key_path"   { type = string }
variable "private_key_path"  { type = string  sensitive = true }
variable "app_dir_remote"    { type = string  default = "/home/ec2-user/app" }
HCL

cat > infra/main.tf <<'HCL'
data "aws_ssm_parameter" "al2023_ami" { name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64" }
resource "aws_vpc" "main" { cidr_block = var.vpc_cidr enable_dns_support = true enable_dns_hostnames = true tags = { Name = "sr-devops-vpc" } }
resource "aws_internet_gateway" "igw" { vpc_id = aws_vpc.main.id tags = { Name = "sr-devops-igw" } }
resource "aws_subnet" "public" { vpc_id = aws_vpc.main.id cidr_block = var.public_subnet_cidr map_public_ip_on_launch = true tags = { Name = "sr-devops-public-subnet" } }
resource "aws_route_table" "public" { vpc_id = aws_vpc.main.id route { cidr_block = "0.0.0.0/0" gateway_id = aws_internet_gateway.igw.id } tags = { Name = "sr-devops-public-rt" } }
resource "aws_route_table_association" "public_assoc" { route_table_id = aws_route_table.public.id subnet_id = aws_subnet.public.id }
resource "aws_security_group" "web_sg" {
  name = "sr-devops-web-sg" description = "Allow HTTP; SSH restricted" vpc_id = aws_vpc.main.id
  ingress { from_port = 80 to_port = 80 protocol = "tcp" cidr_blocks = ["0.0.0.0/0"] }
  ingress { from_port = 22 to_port = 22 protocol = "tcp" cidr_blocks = [var.allowed_ssh_cidr] }
  egress  { from_port = 0 to_port = 0 protocol = "-1" cidr_blocks = ["0.0.0.0/0"] }
  tags = { Name = "sr-devops-web-sg" }
}
resource "aws_key_pair" "this" { key_name = var.key_pair_name public_key = file(var.public_key_path) }
resource "aws_instance" "web" {
  ami = data.aws_ssm_parameter.al2023_ami.value instance_type = var.instance_type
  subnet_id = aws_subnet.public.id vpc_security_group_ids = [aws_security_group.web_sg.id]
  key_name = aws_key_pair.this.key_name associate_public_ip_address = true
  user_data = <<-EOF
    #!/bin/bash
    set -eux
    dnf -y update
    dnf -y install docker
    systemctl enable --now docker
    usermod -aG docker ec2-user
  EOF
  tags = { Name = "sr-devops-web" Project = "sports-reference" }
}
resource "null_resource" "prepare_dir" {
  triggers = { instance_id = aws_instance.web.id }
  provisioner "remote-exec" { inline = ["mkdir -p ${var.app_dir_remote}"] }
  connection { type = "ssh" host = aws_instance.web.public_ip user = "ec2-user" private_key = file(var.private_key_path) }
}
resource "null_resource" "upload_app" {
  depends_on = [null_resource.prepare_dir]
  triggers   = { instance_id = aws_instance.web.id }
  provisioner "file" { source = "${path.module}/../app/Dockerfile" destination = "${var.app_dir_remote}/Dockerfile" }
  provisioner "file" { source = "${path.module}/../app/app.js"    destination = "${var.app_dir_remote}/app.js" }
  provisioner "file" { source = "${path.module}/../app/package.json" destination = "${var.app_dir_remote}/package.json" }
  connection { type = "ssh" host = aws_instance.web.public_ip user = "ec2-user" private_key = file(var.private_key_path) }
}
resource "null_resource" "docker_build_run" {
  depends_on = [null_resource.upload_app]
  triggers   = { instance_id = aws_instance.web.id }
  provisioner "remote-exec" {
    inline = [
      "cd ${var.app_dir_remote}",
      "sudo docker build -t hello-world-node .",
      "sudo docker rm -f hello || true",
      "sudo docker run -d --name hello -p 80:80 hello-world-node"
    ]
  }
  connection { type = "ssh" host = aws_instance.web.public_ip user = "ec2-user" private_key = file(var.private_key_path) }
}
HCL

cat > infra/outputs.tf <<'HCL'
output "public_ip" { description = "Public IP of the EC2 instance" value = aws_instance.web.public_ip }
output "http_url"  { description = "Convenience URL" value = "http://${aws_instance.web.public_ip}/" }
HCL

cat > infra/terraform.tfvars.example <<'HCL'
region            = "us-east-1"
key_pair_name     = "sr-devops-key"
public_key_path   = "~/.ssh/sr-devops.pub"
private_key_path  = "~/.ssh/sr-devops"
allowed_ssh_cidr  = "YOUR.PUBLIC.IP.ADDR/32" # replace!
HCL

cat > app/Dockerfile <<'DOCKER'
FROM node:24-alpine
WORKDIR /usr/src/app
COPY package.json ./
COPY app.js ./
RUN npm install --production
EXPOSE 80
CMD ["npm", "start"]
DOCKER

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
  console.log(`Server running at http://${hostname}:${port}/`);
});
JS

cat > app/package.json <<'JSON'
{
  "name": "hello-world",
  "version": "1.0.0",
  "description": "Simple Hello World app",
  "main": "app.js",
  "scripts": { "start": "node app.js" },
  "dependencies": {}
}
JSON

cat > .gitignore <<'GIT'
node_modules/
npm-debug.log
yarn-error.log
*.tar
*.log
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
*.pem
*.key
*.pub
*.crt
.DS_Store
Thumbs.db
*.swp
*.swo
.idea/
.vscode/
*.bak
dist/
build/
GIT

cat > README.md <<'MD'
# Terraform + Docker + AWS Demo

Deploys a tiny Node.js “Hello, World!” app in a Docker container on an EC2 instance inside a VPC using Terraform.
MD

echo "Created files:"
find . -maxdepth 2 -type f | sort
