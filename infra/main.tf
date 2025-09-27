# Get a current Amazon Linux 2023 AMI via SSM Parameter (region-safe)
data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# --- Networking ---
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "sr-devops-vpc" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "sr-devops-igw" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  map_public_ip_on_launch = true
  tags                    = { Name = "sr-devops-public-subnet" }
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
  ami                         = data.aws_ssm_parameter.al2023_ami.value
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.web_sg.id]
  key_name                    = aws_key_pair.this.key_name
  associate_public_ip_address = true

# Wait until Docker is installed and running (handles user_data timing)
resource "null_resource" "wait_for_docker" {
  depends_on = [aws_instance.web]

  provisioner "remote-exec" {
    inline = [
      # Install if not present (idempotent)
      "if ! command -v docker >/dev/null 2>&1; then sudo dnf -y install docker; fi",
      "sudo systemctl enable --now docker || true",

      # Wait for the docker binary to exist
      "until command -v docker >/dev/null 2>&1; do echo 'waiting for docker binary...'; sleep 5; done",

      # Wait for the docker service to be active
      "until sudo systemctl is-active --quiet docker; do echo 'waiting for docker service...'; sleep 3; done",

      "docker --version || sudo docker --version"
    ]
  }

  connection {
    type        = "ssh"
    host        = aws_instance.web.public_ip
    user        = "ec2-user"
    private_key = file(pathexpand(var.private_key_path))
  }
}

  # Install Docker via user_data (reliable even if provisioner timing is off)
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

# Create remote app dir
resource "null_resource" "prepare_dir" {
  triggers = {
    instance_id = aws_instance.web.id
  }

  provisioner "remote-exec" {
    inline = [
      "mkdir -p ${var.app_dir_remote}"
    ]
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
      # stop/remove if re-applied
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
