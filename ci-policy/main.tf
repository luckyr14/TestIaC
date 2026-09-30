terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

data "aws_caller_identity" "current" {}

locals {
  # Replace ACCOUNT_ID placeholder in the JSON template at apply time.
  policy_json = replace(
    file("${path.module}/ci_policy.json"),
    "ACCOUNT_ID",
    data.aws_caller_identity.current.account_id
  )
}

resource "aws_iam_policy" "ci_least_privilege" {
  name        = "ci-least-privilege"
  description = "Least-privilege policy for the CI user: ECR push, ECS deploy, S3 read."
  policy      = local.policy_json
}

# Attach to the ci user created in the iam/ module.
resource "aws_iam_user_policy_attachment" "ci_attach" {
  user       = "ci"
  policy_arn = aws_iam_policy.ci_least_privilege.arn
}

output "policy_arn" {
  value = aws_iam_policy.ci_least_privilege.arn
}
