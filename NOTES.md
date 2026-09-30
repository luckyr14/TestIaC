# Infrastructure Code — Notes & Step-by-Step Guide

## Directory Structure

```
InfrasturctureCode/
├── modules/ec2-multi-instance/   Task 1 — reusable EC2 module
├── 00-bootstrap/                 Task 2 prereq — creates S3 + DynamoDB
├── main.tf + variables.tf + ...  Tasks 1+2 — root: VPC + EC2 fleet (remote backend)
├── backend.hcl                   Task 2 — partial backend config (update after bootstrap)
├── iam/                          Task 3 — multi-account IAM
├── ci-policy/                    Task 4 — least-privilege CI policy
├── bugfix/                       Task 5 — fixed roleC Terraform
└── NOTES.md
```

---

## Step-by-Step: Running from Scratch

### Prerequisites
```
brew install terraform        # or: https://developer.hashicorp.com/terraform/install
aws configure                 # enter Access Key, Secret Key, region=us-east-1
terraform version             # confirm >= 1.5
```

Your IAM user/role needs: `AmazonEC2FullAccess`, `AmazonVPCFullAccess`,
`AmazonS3FullAccess`, `AmazonDynamoDBFullAccess`, `IAMFullAccess`.

---

### Step 1 — Bootstrap remote state (Task 2 prerequisite)

```bash
cd 00-bootstrap
terraform init
terraform apply
# Type 'yes' when prompted.
```

Note the printed `state_bucket` output value (looks like `tf-state-infra-123456789012`).

---

### Step 2 — Update backend.hcl

Open `backend.hcl` and replace `REPLACE_WITH_YOUR_ACCOUNT_ID` with the actual
account ID (12-digit number) printed in the bootstrap output:

```
bucket = "tf-state-infra-123456789012"   ← replace this line
```

---

### Step 3 — Deploy VPC + EC2 fleet (Tasks 1 + 2)

```bash
cd ..        # back to InfrasturctureCode/
terraform init -backend-config=backend.hcl
terraform plan
terraform apply
# Type 'yes' when prompted.
```

Expected output at the end:
```
instance_ids = {
  "app-server"   = "i-0abc..."
  "cache-server" = "i-0def..."
  "db-server"    = "i-0ghi..."
  "web-server"   = "i-0jkl..."
  "worker"       = "i-0mno..."
}
private_ips = { ... }
public_ips  = { ... }
```

**Verify prevent_destroy works:**
```bash
terraform destroy -target='module.ec2_fleet.aws_instance.protected["db-server"]'
# Terraform will error: "Instance cannot be destroyed" — that is correct.
```

---

### Step 4 — Deploy IAM (Task 3)

```bash
cd iam
terraform init
terraform plan
terraform apply
```

This creates users `engine`, `ci`, `alice`, `bob`; groups `group1` and `group2`;
`roleA` (admin except IAM); `roleB` (assume-roleC-only); and `roleC` in Account B.

**For single-account testing** (default) both `account_a` and `account_b` providers
use your current credentials — `roleC` will be in the same account as roleA/B.
To use two real accounts, edit `providers.tf` and add an `assume_role` block
to the `account_b` provider.

---

### Step 5 — Deploy CI policy (Task 4)

```bash
cd ../ci-policy
# The JSON template substitutes ACCOUNT_ID with your real account ID automatically.
terraform init
terraform apply
```

---

### Step 6 — Review the bugfix (Task 5)

No apply needed — this is a reference file showing the fixed code with
annotated explanations of both bugs.

```bash
cat ../bugfix/main.tf
```

---

### Step 7 — Teardown (to avoid charges)

```bash
# EC2 fleet first (remove prevent_destroy before destroying db-server)
cd ..
terraform destroy    # will fail on db-server — that is the lifecycle guard working

# To actually destroy everything including db-server:
# Edit modules/ec2-multi-instance/main.tf → change prevent_destroy = false → then:
terraform destroy

# IAM
cd iam && terraform destroy

# CI policy
cd ../ci-policy && terraform destroy

# Bootstrap last (destroy EC2/state consumers before removing the state bucket)
cd ../00-bootstrap && terraform destroy   # will fail due to prevent_destroy on bucket
# Remove prevent_destroy from 00-bootstrap/main.tf first, then re-run.
```

---

## Task 1 — Protected Instance

**Which instance:** `db-server`

**Why:** It is the only instance using an `io2` root volume — chosen for high-IOPS
database workloads. Accidental deletion destroys the volume and all data on it unless
a snapshot was taken first. For the other four instances (web, app, cache, worker),
re-creating them from the same AMI restores full functionality because they are
stateless. A database has no such fast recovery path.

**Why two `for_each` resource blocks instead of one:**
Terraform's `lifecycle` block is a *meta-argument*. It is evaluated at plan time
before any expression values are known — it cannot reference `each.key`, variables,
or any dynamic value. The only way to apply `prevent_destroy = true` to one specific
instance while driving the rest from a map is to split the map into two resource
blocks: `aws_instance.standard` (all instances except the protected one) and
`aws_instance.protected` (the one instance with `prevent_destroy = true`).

---

## Task 2 — Remote State and Locking

### What happens without a backend (two concurrent applies)

With local state each engineer has their own `terraform.tfstate` on disk.
When two people run `terraform apply` at the same time:

1. Both read their local state — which may already be stale relative to what the
   other person applied previously.
2. Both generate plans independently, unaware of the other's changes.
3. Both apply concurrently. Depending on timing:
   - The second apply may re-create resources the first just made (duplicates).
   - It may delete resources the first just created (because its plan said to).
   - Whichever apply finishes last overwrites the state file, silently dropping
     resources tracked only by the first run.

The result is **diverged infrastructure and a corrupted or incomplete state file**,
with no error from Terraform — it has no way to detect the conflict.

### How S3 + DynamoDB prevents this

**S3** stores a single shared state file. Every `terraform init` points all engineers
at the same object — one source of truth.

**DynamoDB** provides a distributed lock. When an `apply` (or `plan`) starts,
Terraform writes a `LockID` item to the DynamoDB table using a conditional put
(succeeds only if the item does not already exist). A concurrent `apply` reads the
lock, sees it is held, and immediately fails with a descriptive error naming the
lock holder and timestamp. The lock is released when the operation finishes normally
or is force-unlocked with `terraform force-unlock`.

---

## Task 3 — IAM Questions

### 1. Would you give engine and ci IAM users with access keys in production?

No. Long-lived static access keys are a persistent secret that can be leaked
through git history, CI environment variable dumps, or log files, and remain
valid indefinitely unless actively rotated.

**For `ci`:** Use OIDC federation. GitHub Actions, GitLab CI, and CircleCI all
support issuing a short-lived OIDC token per job. The pipeline exchanges the OIDC
token for temporary AWS credentials via `sts:AssumeRoleWithWebIdentity`. No static
key exists at rest anywhere — not in the repo, not in CI secrets.

**For `engine`:** Remove the IAM user entirely. Engineers authenticate via AWS
IAM Identity Center (SSO) with MFA and assume a role for their session. Credentials
expire automatically (hours, not never), and all access is centrally auditable in
CloudTrail.

IAM users with access keys are a legacy pattern. They should not be created for
new production workloads.

### 2. Trusting Account A root vs. roleB's specific ARN in roleC's trust policy

**Trusting `arn:aws:iam::ACCOUNT_A:root`** delegates access control entirely to
Account A. Any principal in Account A that has been granted `sts:AssumeRole` on
roleC's ARN via Account A's own IAM policies can assume it. Account B has no
independent control over *who* in Account A can get in.

**Trusting `arn:aws:iam::ACCOUNT_A:role/roleB` specifically** means roleC can only
ever be assumed by that exact principal — not by Account A admins, not by the root
user, not by any other role in Account A, even if those principals have been granted
`sts:AssumeRole` permissions internally.

Practical consequence: if Account A is misconfigured or compromised, trusting the
root means any high-privilege Account A identity can immediately pivot into Account B.
Trusting only roleB's ARN contains that blast radius to the single role. For
cross-account access to sensitive resources, always trust the specific ARN.

---

## Task 4 — Deliberate Omissions from the CI Policy

| Excluded | Reason |
|---|---|
| `ecr:CreateRepository`, `ecr:DeleteRepository` | CI pushes to an existing repo; it does not provision ECR |
| `ecr:SetRepositoryPolicy`, `ecr:PutLifecyclePolicy` | CI does not configure the registry |
| `ecs:CreateService`, `ecs:DeleteService`, `ecs:CreateCluster` | CI deploys to an existing service; infrastructure lifecycle is IaC |
| `ecs:RunTask`, `ecs:StopTask` | CI updates the service task definition; it does not schedule ad-hoc tasks |
| `s3:PutObject`, `s3:DeleteObject` on the artifact bucket | The artifact bucket is read-only from CI; writes happen in a separate upload step |
| `s3:PutBucketPolicy`, `s3:GetBucketAcl` | CI reads objects, not bucket metadata or policy |
| `iam:CreateRole`, `iam:AttachRolePolicy` | CI must never be able to escalate its own privileges |
| Wildcard `iam:PassRole` | `iam:PassRole` is included but locked to a single role ARN and constrained with `Condition: iam:PassedToService = ecs-tasks.amazonaws.com` — prevents passing that role to any other AWS service |

---

## Task 5 — Bug Explanation

The broken snippet had two independent bugs:

### Bug 1 — Trust policy: `user/roleB` instead of `role/roleB`

```hcl
# BROKEN:
identifiers = ["arn:aws:iam::000000000000:user/roleB"]

# FIXED:
identifiers = ["arn:aws:iam::000000000000:role/roleB"]
```

roleB is an IAM **Role**. The ARN path for roles is `role/`; for users it is `user/`.
No IAM user named `roleB` exists in Account A, so AWS evaluates the trust policy,
finds no matching entity, and rejects every `sts:AssumeRole` call with `AccessDenied`.
The failure is silent — AWS gives no hint that the principal type in the ARN is wrong.

### Bug 2 — Permissions policy: `Resource = "*"` is too broad

```json
// BROKEN:
{ "Action": "s3:*", "Resource": "*" }

// FIXED (two statements):
{ "Action": ["s3:ListBucket", "s3:GetBucketLocation"], "Resource": "arn:aws:s3:::my-bucket" }
{ "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"], "Resource": "arn:aws:s3:::my-bucket/*" }
```

`Resource = "*"` grants full S3 access to every bucket in Account B. The requirement
is access to *one named bucket*. Two ARN forms are needed because AWS splits
bucket-level operations (e.g., `ListBucket` — requires the bucket ARN without a path)
from object-level operations (e.g., `GetObject` — requires `bucket/*`). Using only
one form silently breaks either listing or object access.
