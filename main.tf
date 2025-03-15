# Configure the AWS provider
provider "aws" {
  region = "us-east-1"  # Change to your preferred region
}

# Generate a unique bucket name
resource "random_id" "bucket_suffix" {
  byte_length = 4
}

# Create an S3 bucket for CTF challenges
resource "aws_s3_bucket" "ctf_challenges_bucket" {
  bucket = "ctf-challenges-bucket-${random_id.bucket_suffix.hex}"
}

# Add a bucket policy to allow the EC2 instance to access the bucket
resource "aws_s3_bucket_policy" "ctf_challenges_bucket_policy" {
  bucket = aws_s3_bucket.ctf_challenges_bucket.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = {
          AWS = aws_iam_role.ctfd_s3_access_role.arn
        }
        Action    = "s3:*"
        Resource  = [
          aws_s3_bucket.ctf_challenges_bucket.arn,
          "${aws_s3_bucket.ctf_challenges_bucket.arn}/*"
        ]
      }
    ]
  })
}

# Create an IAM role for the EC2 instance
resource "aws_iam_role" "ctfd_s3_access_role" {
  name = "ctfd_s3_access_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

# Attach a policy to the IAM role to allow S3 access
resource "aws_iam_role_policy" "ctfd_s3_access_policy" {
  name = "ctfd_s3_access_policy"
  role = aws_iam_role.ctfd_s3_access_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action  = "s3:*"
        Resource = [
          aws_s3_bucket.ctf_challenges_bucket.arn,
          "${aws_s3_bucket.ctf_challenges_bucket.arn}/*"
        ]
      }
    ]
  })
}

# Create an IAM instance profile for the EC2 instance
resource "aws_iam_instance_profile" "ctfd_s3_access_profile" {
  name = "ctfd_s3_access_profile"
  role = aws_iam_role.ctfd_s3_access_role.name
}

# Create a security group for the EC2 instance
resource "aws_security_group" "ctfd_sg" {
  name        = "ctfd_security_group"
  description = "Allow SSH, HTTP, HTTPS, Custom TCP (8000), and ICMP traffic"

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]  # Allow SSH from anywhere (restrict in production)
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]  # Allow HTTP traffic
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]  # Allow HTTPS traffic
  }

  ingress {
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]  # Allow Custom TCP traffic on port 8000
  }

  ingress {
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = ["0.0.0.0/0"]  # Allow all ICMP traffic (IPv4)
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]  # Allow all outbound traffic
  }
}

# Create an EC2 instance for CTFd
resource "aws_instance" "ctfd_instance" {
  ami           = "ami-04b4f1a9cf54c11d0"  # Ubuntu AMI (Free Tier eligible)
  instance_type = "t2.micro"               # Free Tier eligible instance type
  key_name      = "ctfd-key"               # Replace with your EC2 key pair name
  security_groups = [aws_security_group.ctfd_sg.name]
  iam_instance_profile = aws_iam_instance_profile.ctfd_s3_access_profile.name

  # User data to install and configure CTFd
  user_data = <<-EOF
              #!/bin/bash
              # Update the system
              apt-get update -y
              apt-get upgrade -y

              # Install Docker
              apt-get install -y docker.io
              systemctl start docker
              systemctl enable docker

              # Install Docker Compose
              curl -L "https://github.com/docker/compose/releases/download/v2.23.3/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
              chmod +x /usr/local/bin/docker-compose

              # Create a directory for CTFd
              mkdir /opt/ctfd
              cd /opt/ctfd

              # Download the corrected CTFd Docker Compose file
              cat <<EOL > docker-compose.yml
              version: '3'

              services:
                ctfd:
                  image: ctfd/ctfd:latest
                  user: root
                  restart: always
                  ports:
                    - "8000:8000"
                  environment:
                    - UPLOAD_FOLDER=/var/uploads
                    - DATABASE_URL=mysql+pymysql://ctfd:ctfd@db/ctfd
                    - WORKERS=1
                    - LOG_FOLDER=/var/log/CTFd
                    - ACCESS_LOG=-
                    - ERROR_LOG=-
                    - REVERSE_PROXY=true
                  volumes:
                    - .data/CTFd/logs:/var/log/CTFd
                    - .data/CTFd/uploads:/var/uploads
                  depends_on:
                    - db

                db:
                  image: mariadb:10.11
                  restart: always
                  environment:
                    - MARIADB_ROOT_PASSWORD=ctfd
                    - MARIADB_USER=ctfd
                    - MARIADB_PASSWORD=ctfd
                    - MARIADB_DATABASE=ctfd
                    - MARIADB_AUTO_UPGRADE=1
                  volumes:
                    - .data/mysql:/var/lib/mysql
                  command: [mysqld, --character-set-server=utf8mb4, --collation-server=utf8mb4_unicode_ci, --wait_timeout=28800, --log-warnings=0]
              EOL

              # Start CTFd
              docker-compose up -d
              EOF

  tags = {
    Name = "CTFd-Server"
  }
}

# Output the public IP of the EC2 instance
output "public_ip" {
  value = aws_instance.ctfd_instance.public_ip
}

# Output the S3 bucket name
output "s3_bucket_name" {
  value = aws_s3_bucket.ctf_challenges_bucket.bucket
}