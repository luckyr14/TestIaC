# Partial backend configuration — passed via:
#   terraform init -backend-config=backend.hcl
#
# Update bucket with the value printed by 00-bootstrap outputs.
bucket         = "tf-state-infra-REPLACE_WITH_YOUR_ACCOUNT_ID"
key            = "infra/ec2-fleet/terraform.tfstate"
region         = "us-east-1"
dynamodb_table = "terraform-state-lock"
encrypt        = true
