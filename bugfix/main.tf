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
  # Runs in Account B. In production use assume_role to target Account B.
}

data "aws_caller_identity" "current" {}

# ════════════════════════════════════════════════════════════════════════════
# ORIGINAL BROKEN CODE (preserved as comments so the bugs are visible)
# ════════════════════════════════════════════════════════════════════════════
#
# data "aws_iam_policy_document" "roleC_trust" {
#   statement {
#     effect  = "Allow"
#     actions = ["sts:AssumeRole"]
#     principals {
#       type        = "AWS"
#       identifiers = ["arn:aws:iam::000000000000:user/roleB"]  ← BUG 1
#     }
#   }
# }
#
# resource "aws_iam_role_policy" "roleC_s3" {
#   policy = jsonencode({
#     Statement = [{
#       Effect   = "Allow"
#       Action   = "s3:*"      ← BUG 2 (too broad action)
#       Resource = "*"         ← BUG 2 (all buckets, not one named bucket)
#     }]
#   })
# }
#
# BUG 1 — trust policy says "user/roleB" but roleB is a ROLE, not a user.
#   The ARN path for IAM roles is "role/", not "user/".
#   Because no IAM user named roleB exists, AWS evaluates the trust policy,
#   finds no matching principal, and returns AccessDenied on every
#   sts:AssumeRole call — silently, with no hint that the ARN type is wrong.
#   Fix: change "user/roleB" to "role/roleB".
#
# BUG 2 — permissions policy uses Resource = "*" (all S3 buckets in the account).
#   The requirement is full access to ONE named bucket. Using "*" means roleC
#   can read, write, and delete from every bucket in Account B.
#   Fix: scope Resource to the specific bucket ARN.
#   Two ARN forms are required:
#     - "arn:aws:s3:::bucket-name"    for bucket-level ops (ListBucket)
#     - "arn:aws:s3:::bucket-name/*"  for object-level ops (GetObject, PutObject)
# ════════════════════════════════════════════════════════════════════════════

locals {
  account_a_id     = "000000000000"                                          # replace with real Account A ID
  protected_bucket = "production-artifacts-${data.aws_caller_identity.current.account_id}"
}

# ── FIXED trust policy ───────────────────────────────────────────────────────

data "aws_iam_policy_document" "roleC_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type = "AWS"
      # FIX 1: role/roleB  (not user/roleB — roleB is an IAM Role)
      identifiers = ["arn:aws:iam::${local.account_a_id}:role/roleB"]
    }
  }
}

resource "aws_iam_role" "roleC" {
  name               = "roleC"
  assume_role_policy = data.aws_iam_policy_document.roleC_trust.json
}

# ── FIXED permissions policy ─────────────────────────────────────────────────

resource "aws_iam_role_policy" "roleC_s3" {
  name = "roleC-s3-access"
  role = aws_iam_role.roleC.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "BucketLevel"
        Effect = "Allow"
        # FIX 2a: scoped to the single named bucket (bucket-level ops)
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = "arn:aws:s3:::${local.protected_bucket}"
      },
      {
        Sid    = "ObjectLevel"
        Effect = "Allow"
        # FIX 2b: scoped to objects inside the named bucket only
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "arn:aws:s3:::${local.protected_bucket}/*"
      }
    ]
  })
}
