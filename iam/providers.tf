terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# ── Single-account testing ────────────────────────────────────────────────────
# For testing with one AWS account, both providers point to the same credentials.
# In a real two-account setup:
#   provider "aws" { alias = "account_b"; assume_role { role_arn = "arn:aws:iam::111111111111:role/TerraformBootstrap" } }

provider "aws" {
  alias  = "account_a"
  region = "us-east-1"
}

# For single-account testing, account_b reuses the same credentials.
# Replace with a real cross-account assume_role block when you have two accounts.
provider "aws" {
  alias  = "account_b"
  region = "us-east-1"
}
