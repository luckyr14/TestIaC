# Get the real account ID at plan/apply time — no hardcoded 000000000000.
data "aws_caller_identity" "account_a" {
  provider = aws.account_a
}

locals {
  account_a_id = data.aws_caller_identity.account_a.account_id
  # For single-account testing account_b_id == account_a_id.
  # In production replace with the real Account B ID.
  account_b_id = data.aws_caller_identity.account_a.account_id
}

# ── Users ────────────────────────────────────────────────────────────────────

resource "aws_iam_user" "engine" {
  provider = aws.account_a
  name     = "engine"
  tags     = { ManagedBy = "terraform", Group = "group1" }
}

resource "aws_iam_user" "ci" {
  provider = aws.account_a
  name     = "ci"
  tags     = { ManagedBy = "terraform", Group = "group1" }
}

resource "aws_iam_user" "alice" {
  provider      = aws.account_a
  name          = "alice"
  force_destroy = true
  tags          = { ManagedBy = "terraform", Group = "group2" }
}

resource "aws_iam_user" "bob" {
  provider      = aws.account_a
  name          = "bob"
  force_destroy = true
  tags          = { ManagedBy = "terraform", Group = "group2" }
}

# Console login profiles only for group2 members — group1 is programmatic-only.
resource "aws_iam_user_login_profile" "alice" {
  provider                = aws.account_a
  user                    = aws_iam_user.alice.name
  password_reset_required = true
}

resource "aws_iam_user_login_profile" "bob" {
  provider                = aws.account_a
  user                    = aws_iam_user.bob.name
  password_reset_required = true
}

# ── Groups ────────────────────────────────────────────────────────────────────

resource "aws_iam_group" "group1" {
  provider = aws.account_a
  name     = "group1"
}

resource "aws_iam_group" "group2" {
  provider = aws.account_a
  name     = "group2"
}

resource "aws_iam_group_membership" "group1" {
  provider = aws.account_a
  name     = "group1-membership"
  group    = aws_iam_group.group1.name
  users    = [aws_iam_user.engine.name, aws_iam_user.ci.name]
}

resource "aws_iam_group_membership" "group2" {
  provider = aws.account_a
  name     = "group2-membership"
  group    = aws_iam_group.group2.name
  users    = [aws_iam_user.alice.name, aws_iam_user.bob.name]
}

# group1: programmatic-only — deny all console interactions
data "aws_iam_policy_document" "group1_deny_console" {
  provider = aws.account_a
  statement {
    sid       = "DenyConsoleAccess"
    effect    = "Deny"
    actions   = ["aws-portal:*", "signin:*"]
    resources = ["*"]
  }
}

resource "aws_iam_group_policy" "group1_deny_console" {
  provider = aws.account_a
  name     = "deny-console-access"
  group    = aws_iam_group.group1.name
  policy   = data.aws_iam_policy_document.group1_deny_console.json
}

# group2: full console + CLI access via AdministratorAccess managed policy
resource "aws_iam_group_policy_attachment" "group2_admin" {
  provider   = aws.account_a
  group      = aws_iam_group.group2.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# ── roleA — admin for all services except IAM ────────────────────────────────

data "aws_iam_policy_document" "roleA_trust" {
  provider = aws.account_a
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${local.account_a_id}:root"]
    }
  }
}

data "aws_iam_policy_document" "roleA_permissions" {
  provider = aws.account_a
  statement {
    sid           = "AllServicesExceptIAM"
    effect        = "Allow"
    not_actions   = ["iam:*", "organizations:*"]
    resources     = ["*"]
  }
}

resource "aws_iam_role" "roleA" {
  provider           = aws.account_a
  name               = "roleA"
  assume_role_policy = data.aws_iam_policy_document.roleA_trust.json
}

resource "aws_iam_role_policy" "roleA_permissions" {
  provider = aws.account_a
  name     = "admin-except-iam"
  role     = aws_iam_role.roleA.id
  policy   = data.aws_iam_policy_document.roleA_permissions.json
}

# ── roleB — its only permission is to assume roleC in Account B ──────────────

data "aws_iam_policy_document" "roleB_trust" {
  provider = aws.account_a
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${local.account_a_id}:root"]
    }
  }
}

data "aws_iam_policy_document" "roleB_permissions" {
  provider = aws.account_a
  statement {
    sid       = "AssumeRoleCOnly"
    effect    = "Allow"
    actions   = ["sts:AssumeRole"]
    resources = ["arn:aws:iam::${local.account_b_id}:role/roleC"]
  }
}

resource "aws_iam_role" "roleB" {
  provider           = aws.account_a
  name               = "roleB"
  assume_role_policy = data.aws_iam_policy_document.roleB_trust.json
}

resource "aws_iam_role_policy" "roleB_permissions" {
  provider = aws.account_a
  name     = "assume-roleC-only"
  role     = aws_iam_role.roleB.id
  policy   = data.aws_iam_policy_document.roleB_permissions.json
}
