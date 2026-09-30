# Run this ONCE before initialising the root module.
# Creates the S3 bucket and DynamoDB table used by the remote state backend.
# After apply: copy the bucket name from outputs into backend.hcl in the root.

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  # Bootstrap itself uses local state — that is intentional.
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

data "aws_caller_identity" "current" {}

locals {
  # Bucket name includes account ID so it is globally unique without guessing.
  bucket_name = "tf-state-infra-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket" "tf_state" {
  bucket = local.bucket_name

  lifecycle {
    prevent_destroy = true
  }

  tags = { Purpose = "terraform-remote-state" }
}

resource "aws_s3_bucket_versioning" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "tf_state" {
  bucket                  = aws_s3_bucket.tf_state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "tf_lock" {
  name         = "terraform-state-lock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  tags = { Purpose = "terraform-state-lock" }
}

output "state_bucket" {
  value       = aws_s3_bucket.tf_state.bucket
  description = "Paste this into backend.hcl → bucket = \"...\""
}

output "lock_table" {
  value       = aws_dynamodb_table.tf_lock.name
  description = "DynamoDB table name for state locking."
}

output "region" {
  value = var.aws_region
}
