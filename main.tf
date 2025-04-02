# Configure the AWS provider
provider "aws" {
  region = "eu-north-1"
}

# ========== SECRETS MANAGER ==========
resource "null_resource" "delete_old_secret" {
  triggers = {
    always_run = timestamp()
  }

  provisioner "local-exec" {
    command = <<EOT
      # Check if secret exists and is marked for deletion
      if aws secretsmanager describe-secret --secret-id ctfd_admin_token --region eu-north-1 >/dev/null 2>&1; then
        STATUS=$(aws secretsmanager describe-secret --secret-id ctfd_admin_token --region eu-north-1 --query 'DeletedDate' --output text)
        if [ "$STATUS" != "None" ]; then
          # Secret is pending deletion - restore it first
          aws secretsmanager restore-secret --secret-id ctfd_admin_token --region eu-north-1
          sleep 5
        fi
        # Now delete properly
        aws secretsmanager delete-secret \
          --secret-id ctfd_admin_token \
          --force-delete-without-recovery \
          --region eu-north-1 || true
        # Wait for deletion to complete
        sleep 30
      fi
    EOT
  }
}

resource "aws_secretsmanager_secret" "ctfd_token" {
  name        = "ctfd_admin_token"
  description = "API token for CTFd admin access"

  depends_on = [null_resource.delete_old_secret]
}

resource "aws_secretsmanager_secret_version" "ctfd_token" {
  secret_id     = aws_secretsmanager_secret.ctfd_token.id
  secret_string = "initial_token_placeholder"

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# ========== VPC NETWORKING ==========
resource "aws_vpc" "ctfd_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
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
  map_public_ip_on_launch = true
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

# ========== IAM ROLES ==========
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
      },
      {
        Effect   = "Allow",
        Action   = [
          "secretsmanager:PutSecretValue",
          "secretsmanager:GetSecretValue"
        ],
        Resource = aws_secretsmanager_secret.ctfd_token.arn
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
  description = "Allow all necessary traffic for CTFd"
  vpc_id      = aws_vpc.ctfd_vpc.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ========== LAMBDA FUNCTION FOR S3 SYNC ==========
resource "aws_iam_role" "lambda_exec" {
  name = "ctfd_lambda_exec_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "lambda_policy" {
  name = "ctfd_lambda_policy"
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ],
        Resource = [
          aws_s3_bucket.ctf_challenges_bucket.arn,
          "${aws_s3_bucket.ctf_challenges_bucket.arn}/*"
        ]
      },
      {
        Effect = "Allow",
        Action = [
          "secretsmanager:GetSecretValue"
        ],
        Resource = [
          aws_secretsmanager_secret.ctfd_token.arn
        ]
      },
      {
        Effect = "Allow",
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ],
        Resource = ["*"]
      }
    ]
  })
}

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambda"
  output_path = "${path.module}/lambda_function.zip"
}

resource "aws_lambda_function" "sync_challenges" {
  filename      = "lambda_function.zip"
  function_name = "ctfd_sync_challenges"
  role          = aws_iam_role.lambda_exec.arn
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.8"
  timeout       = 30

  environment {
    variables = {
      CTFD_URL    = "http://${aws_instance.ctfd_instance.private_ip}:8000"
      SECRET_NAME = aws_secretsmanager_secret.ctfd_token.name
    }
  }

  depends_on = [
    aws_instance.ctfd_instance,
    data.archive_file.lambda_zip
  ]
}

resource "aws_lambda_permission" "allow_bucket" {
  statement_id  = "AllowExecutionFromS3Bucket"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.sync_challenges.arn
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.ctf_challenges_bucket.arn
}

resource "aws_s3_bucket_notification" "bucket_notification" {
  bucket = aws_s3_bucket.ctf_challenges_bucket.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.sync_challenges.arn
    events              = ["s3:ObjectCreated:*"]
    filter_suffix       = ".yaml"
  }

  depends_on = [aws_lambda_permission.allow_bucket]
}

# ========== EC2 INSTANCE ==========
resource "aws_instance" "ctfd_instance" {
  ami           = "ami-0989fb15ce71ba39e" # Ubuntu 22.04 LTS in eu-north-1
  instance_type = "t3.small" # Micro might be too small for CTFd
  key_name      = "knightecKey"
  subnet_id     = aws_subnet.ctfd_subnet.id
  vpc_security_group_ids = [aws_security_group.ctfd_sg.id]
  iam_instance_profile = aws_iam_instance_profile.ctfd_s3_access_profile.name

  user_data = <<-EOF
              #!/bin/bash
              # Install dependencies
              apt-get update -y
              apt-get install -y \
                  apt-transport-https \
                  ca-certificates \
                  curl \
                  gnupg \
                  lsb-release \
                  jq \
                  python3-pip \
                  unzip

              # Install Docker
              mkdir -p /etc/apt/keyrings
              curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
              echo \
                "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
                $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
              apt-get update -y
              apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

              # Start and enable Docker
              systemctl enable docker
              systemctl start docker

              # Create CTFd directory
              mkdir -p /opt/ctfd
              cd /opt/ctfd

              # Docker Compose config
              cat <<EOL > docker-compose.yml
              version: '3'
              services:
                ctfd:
                  image: ctfd/ctfd:latest
                  restart: unless-stopped
                  ports:
                    - "8000:8000"
                  environment:
                    - UPLOAD_FOLDER=/var/uploads
                    - DATABASE_URL=mysql+pymysql://ctfd:ctfd@db/ctfd
                    - SECRET_KEY=${random_id.bucket_suffix.hex}${random_id.bucket_suffix.hex}
                    - SETUP_ADMIN_EMAIL=admin@ctfd.local
                    - SETUP_ADMIN_PASSWORD=ChangeMe123!
                  volumes:
                    - ctfd-data:/var/uploads
                  depends_on:
                    - db

                db:
                  image: mariadb:10.11
                  restart: unless-stopped
                  environment:
                    - MARIADB_ROOT_PASSWORD=ctfd
                    - MARIADB_USER=ctfd
                    - MARIADB_PASSWORD=ctfd
                    - MARIADB_DATABASE=ctfd
                  volumes:
                    - db-data:/var/lib/mysql

              volumes:
                ctfd-data:
                db-data:
              EOL

              # Start services
              docker compose up -d

              # Install CTFd CLI for challenge management
              pip3 install ctfd-parser

              # Wait for CTFd to initialize (up to 5 minutes)
              for i in {1..30}; do
                if curl -s http://localhost:8000 >/dev/null; then
                  # Generate and store admin token
                  ADMIN_TOKEN=$(curl -s -X POST http://localhost:8000/api/v1/tokens \
                    -H "Content-Type: application/json" \
                    -d '{"name":"automation"}' \
                    --user "admin@ctfd.local:ChangeMe123!" | jq -r '.data.value')
                  
                  if [ -n "$ADMIN_TOKEN" ]; then
                    aws secretsmanager put-secret-value \
                      --secret-id ${aws_secretsmanager_secret.ctfd_token.name} \
                      --secret-string "$ADMIN_TOKEN" \
                      --region eu-north-1
                    break
                  fi
                fi
                sleep 10
              done
              EOF

  tags = {
    Name = "CTFd-Server"
  }

  depends_on = [aws_secretsmanager_secret_version.ctfd_token]
}

resource "aws_eip" "ctfd_eip" {
  domain   = "vpc"
  instance = aws_instance.ctfd_instance.id
}

# ========== OUTPUTS ==========
output "ctfd_url" {
  value = "http://${aws_eip.ctfd_eip.public_ip}:8000"
}

output "admin_credentials" {
  value = {
    email    = "admin@ctfd.local"
    password = "ChangeMe123!"
  }
  sensitive = true
}

output "s3_bucket_name" {
  value = aws_s3_bucket.ctf_challenges_bucket.bucket
}

output "ssh_command" {
  value = "ssh -i knightecKey.pem ubuntu@${aws_eip.ctfd_eip.public_ip}"
}

output "secret_arn" {
  value = aws_secretsmanager_secret.ctfd_token.arn
}