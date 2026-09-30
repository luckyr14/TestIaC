# ── roleC — S3 access to one named bucket, assumable only by roleB ───────────
#
# Trust policy references roleB's specific ARN, NOT the Account A root.
# See NOTES.md Task 3 Q2 for why this distinction matters.

locals {
  protected_bucket = "production-artifacts-${local.account_b_id}"
}

data "aws_iam_policy_document" "roleC_trust" {
  provider = aws.account_b

  statement {
    sid     = "AllowRoleBOnly"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type = "AWS"
      # Specific ARN of roleB — not the account root.
      identifiers = ["arn:aws:iam::${local.account_a_id}:role/roleB"]
    }
  }
}

data "aws_iam_policy_document" "roleC_s3" {
  provider = aws.account_b

  # Bucket-level operations: ListBucket, GetBucketLocation
  statement {
    sid       = "BucketLevel"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = ["arn:aws:s3:::${local.protected_bucket}"]
  }

  # Object-level operations: full access inside the bucket
  statement {
    sid       = "ObjectLevel"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["arn:aws:s3:::${local.protected_bucket}/*"]
  }
}

resource "aws_iam_role" "roleC" {
  provider           = aws.account_b
  name               = "roleC"
  assume_role_policy = data.aws_iam_policy_document.roleC_trust.json
}

resource "aws_iam_role_policy" "roleC_s3" {
  provider = aws.account_b
  name     = "s3-single-bucket-only"
  role     = aws_iam_role.roleC.id
  policy   = data.aws_iam_policy_document.roleC_s3.json
}
