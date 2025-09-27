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
  
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
      kms_master_key_id = null
    }
    bucket_key_enabled = false
  }
}

resource "aws_dynamodb_table" "tflock" {
  name         = var.dynamodb_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute { name = "LockID" type = "S" }
}

output "backend_bucket" { value = aws_s3_bucket.tfstate.bucket }
output "backend_table"  { value = aws_dynamodb_table.tflock.name }
