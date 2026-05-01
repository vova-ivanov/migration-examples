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
  }
}

provider "aws" {
  region = "us-west-2"
}

resource "random_id" "suffix" {
  byte_length = 4
}

# Shared S3 bucket — both module instances write to it, referencing the name
# via environment variables. In AWS the bucket has no indication it is shared
# between two functions that were created from the same module.
resource "aws_s3_bucket" "shared" {
  bucket = "terraform-modules-demo-${random_id.suffix.hex}"
}

resource "aws_iam_policy" "s3_readwrite" {
  name = "terraform-modules-demo-s3-${random_id.suffix.hex}"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
      Resource = [aws_s3_bucket.shared.arn, "${aws_s3_bucket.shared.arn}/*"]
    }]
  })
}

# ── Module instances ───────────────────────────────────────────────────────────
# The same module is called twice with different parameter sets.
#
# Migration challenge: AWS sees two Lambda functions, two IAM roles, and one
# S3 bucket. Nothing in the AWS API indicates:
#   • the two functions were created from the same module definition
#   • the ROLE env var distinguishes their intended behaviour
#   • the shared S3 bucket is an intentional cross-instance dependency
#
# A migration tool that snapshots AWS resources and generates Pulumi code will
# produce two independent, copy-pasted resource blocks. The DRY abstraction
# encoded in the module is silently lost.

module "processor" {
  source     = "./modules/lambda-app"
  name       = "terraform-modules-processor-${random_id.suffix.hex}"
  lambda_zip = "${path.module}/lambda.zip"
  timeout    = 60
  environment = {
    ROLE   = "processor"
    BUCKET = aws_s3_bucket.shared.id
  }
  tags = {
    Module = "lambda-app"
    Role   = "processor"
  }
}

module "notifier" {
  source     = "./modules/lambda-app"
  name       = "terraform-modules-notifier-${random_id.suffix.hex}"
  lambda_zip = "${path.module}/lambda.zip"
  timeout    = 30
  environment = {
    ROLE   = "notifier"
    BUCKET = aws_s3_bucket.shared.id
  }
  tags = {
    Module = "lambda-app"
    Role   = "notifier"
  }
}

# S3 policy attached at root level — both module instances share the same
# policy. In AWS you see four policy attachments with no indication two of them
# correspond to a shared S3 grant that was added outside the module boundary.
resource "aws_iam_role_policy_attachment" "processor_s3" {
  role       = module.processor.role_name
  policy_arn = aws_iam_policy.s3_readwrite.arn
}

resource "aws_iam_role_policy_attachment" "notifier_s3" {
  role       = module.notifier.role_name
  policy_arn = aws_iam_policy.s3_readwrite.arn
}

# ── Outputs ────────────────────────────────────────────────────────────────────

output "processor_name" {
  value = module.processor.function_name
}

output "notifier_name" {
  value = module.notifier.function_name
}

output "shared_bucket" {
  value = aws_s3_bucket.shared.id
}

output "suffix" {
  value       = random_id.suffix.hex
  description = "Random suffix (local resource — no AWS counterpart)"
}
