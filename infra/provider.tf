terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }

  # Backend values are passed via -backend-config on `terraform init`
  backend "s3" {}
}

provider "aws" {
  region = var.region
}
