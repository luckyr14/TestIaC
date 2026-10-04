# DevOps Assignment: Notes

Order of work: **Task 2 (backend bootstrap) -> Task 1 (EC2 module)** -> Tasks 3, 4, 5 (written answers only).

```
01-backend-bootstrap/   Task 2: creates S3 bucket + DynamoDB lock table
02-ec2-module/          Task 1: module + root config using that backend
NOTES.md
```

**How to run**
```bash
cd 01-backend-bootstrap && terraform init && terraform apply -var state_bucket_name=<unique-name>
# put that bucket name into 02-ec2-module/backend.tf
cd ../02-ec2-module && terraform init && terraform plan && terraform apply
```

---

## Task 2: Remote State & Locking

**What was added**
- `01-backend-bootstrap/`: an S3 bucket (versioned, encrypted, public access blocked, `prevent_destroy`) and a DynamoDB table with hash key `LockID`.
- `02-ec2-module/backend.tf`: a `backend "s3"` block with `dynamodb_table` and `encrypt = true`.
- The bootstrap is a separate config because a backend cannot create its own storage. It is applied once with local state, and everything else then uses the remote backend.

**What happens today (local state) if two people apply at the same time**
- Local state lives in a `terraform.tfstate` file on each person's machine. There is no shared source of truth and no lock.
- If each person has their own copy, both plans are computed against stale or different state. Both applies create the same resources (duplicate instances, name conflicts), or one tries to modify something the other is deleting.
- If the file is shared (git, a shared drive), the last writer overwrites the other's changes. State then no longer matches real infrastructure, which leads to orphaned resources, drift, or a corrupted file.

**How the backend change prevents it**
- When `apply` starts, Terraform writes a lock item (`LockID` = `<bucket>/<key>`) to DynamoDB using a **conditional write** that only succeeds if the item does not already exist. DynamoDB guarantees that only one caller wins.
- The second person gets `Error acquiring the state lock`, showing who holds it, the operation, and when it started. They can wait using `-lock-timeout=5m`.
- The lock is released when the apply finishes. `terraform force-unlock <ID>` exists for a crashed run, and should be used carefully.
- State is stored once in S3, so everyone sees the same state. Versioning lets you recover an earlier state after a bad write.
- Note: Terraform 1.10+ also supports `use_lockfile = true` (S3-native locking, no DynamoDB), and DynamoDB locking is being deprecated. DynamoDB is used here because the assignment asks for it.

---

## Task 1: Multi-Instance EC2 Provisioning

| Name   | Type      | Root volume        | Key pair   | Protected |
|--------|-----------|--------------------|------------|-----------|
| web    | t3.micro  | gp3, 20 GB         | key-web    |           |
| api    | t3.small  | gp3, 30 GB         | key-api    |           |
| worker | t3.medium | gp2, 40 GB         | key-worker |           |
| cache  | r5.large  | gp3, 50 GB, 4000 iops | key-cache |        |
| db     | m5.large  | **io2**, 100 GB, 3000 iops | key-db | **yes** |

- One input variable, `instances` (`map(object(...))`), drives everything through `for_each`. No hardcoded per-instance resource blocks.
- Every instance is tagged `Name` (the map key), `Environment`, and `Owner`.
- Validation rules enforce exactly 5 instances, at least one io1/io2 volume, `iops` set for io1/io2, and exactly one protected instance.
- Outputs: `instance_ids` (name -> ID) and `instance_private_ips` (name -> private IP).
- Key pairs must already exist in the region.

**Which instance is protected and why: `db`**
- It is the stateful, hardest-to-recreate machine, and its io2 volume holds data that cannot be rebuilt from code. The others are stateless and can be recreated from the module.
- `prevent_destroy = true` makes `terraform destroy`, or any change that forces a replacement, fail with an error instead of deleting it.
- **Design note:** `prevent_destroy` must be a literal `true`, not a variable or `each.key`. So the map is split into `protected` and `normal` using a `protected` flag, with two `aws_instance` resources and the lifecycle block on only one. The outputs `merge()` both.
- Limitation: it only protects against Terraform. Someone deleting the instance in the console or CLI is not stopped. For that, also enable EC2 termination protection (`disable_api_termination`).

---

## Task 3: Multi-Account IAM & Cross-Account Access (design)

**Account A (000000000000)**
- `group1` (programmatic only): users `engine` and `ci`. No console login profile, so access keys only.
- `group2` (console + CLI): users `alice` and `bob`, with console passwords (forced reset) and MFA.
- `roleA`: a single statement with `Effect: Allow`, `NotAction: "iam:*"`, `Resource: "*"`. That gives administrative access to everything except IAM. Its trust policy allows group2 users (with MFA) to assume it.
- `roleB`: its only permission is to assume roleC.

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": "sts:AssumeRole",
    "Resource": "arn:aws:iam::111111111111:role/roleC"
  }]
}
```

**Account B (111111111111)**
- `roleC`: full access to one bucket (`my-shared-bucket`), trusted only by roleB (see Task 5 for the trust and permission policies).
- Cross-account access needs **both sides**: roleB's identity policy allows `sts:AssumeRole` on roleC, and roleC's trust policy allows roleB.

**1. Would I give `engine` and `ci` IAM users with access keys in real production?**
No. Long-lived access keys are the most commonly leaked credential type. They do not expire, they end up in repos, logs and laptops, and they are hard to rotate and audit per person or job. I would use:
- **CI:** OIDC federation (for example GitHub Actions or GitLab to an IAM role with `AssumeRoleWithWebIdentity`). Credentials are short-lived and scoped to a repo/branch through the trust policy's `sub` condition.
- **Humans and "engine" style accounts:** IAM Identity Center (SSO) with short-lived sessions, or roles assumed from a central identity.
- **Workloads:** instance profiles, ECS task roles, or IRSA, never keys.
- If keys are unavoidable: least-privilege policy, MFA or IP/condition restrictions, 90-day rotation, secrets manager storage, and alerts on use.

**2. In roleC's trust policy, trusting Account A root vs. roleB's ARN**
- Trusting `arn:aws:iam::000000000000:root` means "anyone in Account A the admin of Account A chooses to allow." Any user or role in Account A that has `sts:AssumeRole` permission on roleC can assume it. That includes roleA (admin), CI users, and any compromised or future principal. Security then depends on Account A's IAM hygiene, which Account B does not control.
- Trusting `.../role/roleB` means only that one role can assume it. Even an admin in Account A cannot use roleC without going through roleB.
- It is least privilege at the trust boundary: Account B defines exactly who may enter, instead of delegating that decision to another account.

---

## Task 4: Least-Privilege Policy for `ci`

Placeholders: region `ap-south-1`, account `000000000000`, repo `my-app`, cluster `my-cluster`, service `my-service`, bucket `my-build-artifacts`. Replace with real values.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EcrLogin",
      "Effect": "Allow",
      "Action": "ecr:GetAuthorizationToken",
      "Resource": "*"
    },
    {
      "Sid": "EcrPushToOneRepo",
      "Effect": "Allow",
      "Action": [
        "ecr:BatchCheckLayerAvailability",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload",
        "ecr:PutImage"
      ],
      "Resource": "arn:aws:ecr:ap-south-1:000000000000:repository/my-app"
    },
    {
      "Sid": "EcsTaskDefinitions",
      "Effect": "Allow",
      "Action": [
        "ecs:RegisterTaskDefinition",
        "ecs:DescribeTaskDefinition"
      ],
      "Resource": "*"
    },
    {
      "Sid": "EcsDeployToOneService",
      "Effect": "Allow",
      "Action": [
        "ecs:UpdateService",
        "ecs:DescribeServices"
      ],
      "Resource": "arn:aws:ecs:ap-south-1:000000000000:service/my-cluster/my-service"
    },
    {
      "Sid": "PassOnlyTheTaskRoles",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": [
        "arn:aws:iam::000000000000:role/my-app-task-role",
        "arn:aws:iam::000000000000:role/my-app-task-execution-role"
      ],
      "Condition": {
        "StringEquals": { "iam:PassedToService": "ecs-tasks.amazonaws.com" }
      }
    },
    {
      "Sid": "ReadArtifactsBucketList",
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::my-build-artifacts"
    },
    {
      "Sid": "ReadArtifactsObjects",
      "Effect": "Allow",
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::my-build-artifacts/*"
    }
  ]
}
```

**Why a few things use `Resource: "*"`:** `ecr:GetAuthorizationToken`, `ecs:RegisterTaskDefinition` and `ecs:DescribeTaskDefinition` do not support resource-level permissions, so `*` is the only option. Everything that can be scoped is scoped.

**What I deliberately left out, and why**
- **`ecr:*` / pull actions (`BatchGetImage`, `GetDownloadUrlForLayer`):** CI only pushes. Pulling is done by the ECS execution role, not CI.
- **`ecr:CreateRepository`, `DeleteRepository`, `BatchDeleteImage`:** CI must not create or destroy repos or delete images.
- **`ecs:*`, `CreateService`, `DeleteService`, `RunTask`, `DeregisterTaskDefinition`, cluster actions:** the job is only to roll out a new revision to an existing service. No creating or deleting infrastructure.
- **`s3:PutObject`, `DeleteObject`, `s3:*`:** the requirement says read-only. Write access would let a compromised pipeline tamper with build artifacts.
- **Wildcard bucket/repo ARNs and `Resource: "*"` on S3/ECR/ECS actions:** scoped to single named resources to limit blast radius.
- **`iam:PassRole` on `*`:** a wide-open PassRole is a classic privilege-escalation path. It is restricted to the two task roles and to `ecs-tasks.amazonaws.com`. It is also easy to forget, and without it `RegisterTaskDefinition`/`UpdateService` fails.
- **`iam:*`, `sts:*`, `logs:*`, `cloudformation:*`, `ec2:*`:** not needed for these three jobs.

---

## Task 5: Find and Fix the Bug

**Fixed code**
```hcl
data "aws_iam_policy_document" "roleC_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::000000000000:role/roleB"]   # role/, not user/
    }
  }
}

resource "aws_iam_role" "roleC" {
  name               = "roleC"
  assume_role_policy = data.aws_iam_policy_document.roleC_trust.json
}

resource "aws_iam_role_policy" "roleC_s3" {
  name = "roleC-s3-access"
  role = aws_iam_role.roleC.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "s3:*"
      Resource = [
        "arn:aws:s3:::my-shared-bucket",     # bucket-level actions (ListBucket, etc.)
        "arn:aws:s3:::my-shared-bucket/*"    # object-level actions (Get/Put/Delete)
      ]
    }]
  })
}
```

**Bug 1, trust policy: wrong principal type (`user/roleB` instead of `role/roleB`)**
- The ARN says "an IAM *user* named roleB in Account A", but roleB is an IAM *role*. The ARN path is part of the identity, so `user/roleB` is a different identity from `role/roleB`.
- Consequence: when the trust policy is saved, IAM checks the principal and either rejects it (`MalformedPolicyDocument: Invalid principal in policy`) because no such user exists, or, if a user with that name ever exists, it would trust the wrong identity. roleB itself could never assume roleC, because its ARN does not match.
- Fix: use `arn:aws:iam::000000000000:role/roleB`. If roleB has a path (for example `role/team/roleB`), the path must be included.

**Bug 2, permissions policy: `s3:*` on `Resource = "*"`**
- This grants every S3 action on **every bucket in Account B**, not the single named bucket the requirement calls for. It breaks least privilege, and anyone who assumes roleC could read, overwrite, or delete any bucket in that account.
- Fix: scope to the bucket ARN (for bucket-level actions like `s3:ListBucket`) **and** `bucket/*` (for object-level actions like `GetObject`/`PutObject`). Both entries are needed, since bucket actions apply to the bucket ARN and object actions to the `/*` ARN.

**Also remember:** even with the trust policy fixed, roleB must have its own identity policy allowing `sts:AssumeRole` on `arn:aws:iam::111111111111:role/roleC` (see Task 3). Cross-account access needs permission on both sides.
