# Configure the AWS provider
provider "aws" {
  region = "eu-north-1"  # Using Stockholm region
}

# ========== VPC NETWORKING ==========
resource "aws_vpc" "ctfd_vpc" {
  cidr_block = "10.0.0.0/16"
  tags = {
    Name = "CTFd-VPC"
  }
}

resource "aws_internet_gateway" "ctfd_igw" {
  vpc_id = aws_vpc.ctfd_vpc.id
  tags = {
    Name = "CTFd-IGW"
  }
}

resource "aws_subnet" "ctfd_subnet" {
  vpc_id                  = aws_vpc.ctfd_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "eu-north-1a"
  map_public_ip_on_launch = true  # CRITICAL FOR PUBLIC IP
  tags = {
    Name = "CTFd-Subnet"
  }
}

resource "aws_route_table" "ctfd_rt" {
  vpc_id = aws_vpc.ctfd_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.ctfd_igw.id
  }

  tags = {
    Name = "CTFd-RouteTable"
  }
}

resource "aws_route_table_association" "ctfd_rta" {
  subnet_id      = aws_subnet.ctfd_subnet.id
  route_table_id = aws_route_table.ctfd_rt.id
}

# ========== S3 BUCKET ==========
resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "ctf_challenges_bucket" {
  bucket = "ctf-challenges-bucket-${random_id.bucket_suffix.hex}"
}

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

# ========== IAM ROLE ==========
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

resource "aws_iam_instance_profile" "ctfd_s3_access_profile" {
  name = "ctfd_s3_access_profile"
  role = aws_iam_role.ctfd_s3_access_role.name
}

# ========== SECURITY GROUP ==========
resource "aws_security_group" "ctfd_sg" {
  name        = "ctfd_security_group"
  description = "Allow SSH, HTTP, HTTPS, Custom TCP (8000), and ICMP traffic"
  vpc_id      = aws_vpc.ctfd_vpc.id

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

# ========== EC2 INSTANCE ==========
resource "aws_instance" "ctfd_instance" {
  ami           = "ami-0c1ac8a41498c1a9c"  # Ubuntu 22.04 in eu-north-1
  instance_type = "t3.micro"               # Supported in eu-north-1
  key_name      = "knightecKey"            # Ensure this key exists in eu-north-1
  subnet_id     = aws_subnet.ctfd_subnet.id
  vpc_security_group_ids = [aws_security_group.ctfd_sg.id]
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

# ========== ELASTIC IP ==========
resource "aws_eip" "ctfd_eip" {
  vpc      = true
  instance = aws_instance.ctfd_instance.id
}

# ========== OUTPUTS ==========
output "public_ip" {
  value = aws_eip.ctfd_eip.public_ip  # Guaranteed static public IP
}

output "s3_bucket_name" {
  value = aws_s3_bucket.ctf_challenges_bucket.bucket
}