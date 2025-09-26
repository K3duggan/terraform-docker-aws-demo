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
  description = "Path to your local *public* SSH key (e.g., ~/.ssh/id_rsa.pub)"
  type        = string
}

variable "private_key_path" {
  description = "Path to your local *private* SSH key (e.g., ~/.ssh/id_rsa)"
  type        = string
  sensitive   = true
}

# Docker app config
variable "app_dir_remote" {
  description = "Destination directory on the EC2 host where app files are uploaded"
  type        = string
  default     = "/home/ec2-user/app"
}
