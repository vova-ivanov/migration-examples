terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.11"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = "us-west-2"
}

# Local resource — generates a random suffix tracked in Terraform state,
# but makes no AWS API calls and has no physical presence on AWS.
resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "main" {
  bucket = "terraform-random-demo-${random_id.bucket_suffix.hex}"
}

resource "aws_s3_bucket_versioning" "main" {
  bucket = aws_s3_bucket.main.id
  versioning_configuration {
    status = "Enabled"
  }
}

# random_pet: human-readable name, local-only
resource "random_pet" "lambda_name" {
  length    = 2
  separator = "-"
}

# time_static: captures the moment apply first ran, never changes on re-apply
resource "time_static" "deployed_at" {}

# tls_private_key: key pair generated locally, never sent to AWS
resource "tls_private_key" "lambda_key" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "aws_iam_role" "lambda" {
  name = "terraform-random-lambda-${random_id.bucket_suffix.hex}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_lambda_function" "demo" {
  function_name = random_pet.lambda_name.id
  role          = aws_iam_role.lambda.arn
  runtime       = "python3.12"
  handler       = "index.handler"

  filename         = "${path.module}/lambda.zip"
  source_code_hash = filebase64sha256("${path.module}/lambda.zip")

  # These env vars surface the local-resource values in the Lambda console
  environment {
    variables = {
      DEPLOYED_AT    = time_static.deployed_at.rfc3339
      PUBLIC_KEY_PEM = tls_private_key.lambda_key.public_key_pem
      RANDOM_SUFFIX  = random_id.bucket_suffix.hex
    }
  }

  tags = {
    DeployedAt = time_static.deployed_at.rfc3339
    PetName    = random_pet.lambda_name.id
  }
}

output "bucket_name" {
  value = aws_s3_bucket.main.bucket
}

output "random_suffix" {
  value       = random_id.bucket_suffix.hex
  description = "The random suffix (local resource, no AWS counterpart)"
}

output "lambda_name" {
  value = aws_lambda_function.demo.function_name
}

output "deployed_at" {
  value = time_static.deployed_at.rfc3339
}
