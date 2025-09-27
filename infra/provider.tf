terraform {
  required_version = ">= 1.13.3"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }

  # Backend values are passed via -backend-config on `terraform init`
  backend "s3" {}
}

provider "aws" {
  region = var.region
}
