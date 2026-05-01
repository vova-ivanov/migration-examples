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

# ── Data sources ──────────────────────────────────────────────────────────────
# Data sources query existing AWS state and generate computed values. They make
# no write calls to AWS and create no resources. Discovery tools that enumerate
# AWS APIs will never see them; the relationships and computed values they
# encode are completely invisible without the Terraform source.

# Current caller — resolves account ID without hard-coding it.
data "aws_caller_identity" "current" {}

# Current region — resolves the region name without hard-coding it.
data "aws_region" "current" {}

# aws_iam_policy_document generates IAM policy JSON from HCL. The policy that
# ends up in AWS is byte-for-byte identical to one written by hand. A discovery
# tool sees the finished JSON; the HCL template that generated it is gone.
data "aws_iam_policy_document" "assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "permissions" {
  statement {
    sid     = "SSM"
    effect  = "Allow"
    actions = ["ssm:GetParameter", "ssm:GetParametersByPath"]
    resources = [
      "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter/terraform-datasources-demo/*"
    ]
  }
  statement {
    sid     = "Logs"
    effect  = "Allow"
    actions = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["*"]
  }
}

# ── Real resources ─────────────────────────────────────────────────────────────

resource "random_id" "suffix" {
  byte_length = 4
}

# SSM parameters (real AWS resources). They are also read back via a data
# source below to demonstrate how a resolved value gets stamped into the Lambda
# at apply time — after which AWS has no record of the lookup.
resource "aws_ssm_parameter" "app_config" {
  name  = "/terraform-datasources-demo/app-config"
  type  = "String"
  value = "region=${data.aws_region.current.name},account=${data.aws_caller_identity.current.account_id}"
}

resource "aws_ssm_parameter" "feature_flags" {
  name  = "/terraform-datasources-demo/feature-flags"
  type  = "String"
  value = "dark-mode=true,new-checkout=false"
}

# Read the parameter back via a data source. The resolved value is injected
# into the Lambda as a static env var. AWS shows it as a plain string; the
# SSM lookup that produced it is invisible.
data "aws_ssm_parameter" "app_config" {
  name       = aws_ssm_parameter.app_config.name
  depends_on = [aws_ssm_parameter.app_config]
}

resource "aws_iam_role" "lambda" {
  name               = "terraform-datasources-demo-${random_id.suffix.hex}"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

resource "aws_iam_role_policy" "lambda_permissions" {
  name   = "terraform-datasources-demo-permissions"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.permissions.json
}

resource "aws_lambda_function" "demo" {
  function_name = "terraform-datasources-demo-${random_id.suffix.hex}"
  role          = aws_iam_role.lambda.arn
  runtime       = "python3.12"
  handler       = "index.handler"

  filename         = "${path.module}/lambda.zip"
  source_code_hash = filebase64sha256("${path.module}/lambda.zip")

  environment {
    variables = {
      # These values were resolved by data sources at apply time and baked in
      # as static strings. In the Lambda console they appear no different from
      # values typed by hand; the data source chain is invisible.
      ACCOUNT_ID   = data.aws_caller_identity.current.account_id
      REGION       = data.aws_region.current.name
      APP_CONFIG   = data.aws_ssm_parameter.app_config.value
      PARAM_PREFIX = "/terraform-datasources-demo/"
    }
  }
}

# ── Outputs ────────────────────────────────────────────────────────────────────

output "lambda_name" {
  value = aws_lambda_function.demo.function_name
}

output "account_id" {
  value       = data.aws_caller_identity.current.account_id
  description = "Resolved by data source at apply time — no AWS resource created"
}

output "region" {
  value       = data.aws_region.current.name
  description = "Resolved by data source at apply time — no AWS resource created"
}

output "ssm_config_param" {
  value = aws_ssm_parameter.app_config.name
}
