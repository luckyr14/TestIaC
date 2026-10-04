locals {
  protected_instances = { for k, v in var.instances : k => v if v.protected }
  normal_instances    = { for k, v in var.instances : k => v if !v.protected }

  common_tags = {
    Environment = var.environment
    Owner       = var.owner
  }
}

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023*-x86_64"]
  }
}

resource "aws_instance" "normal" {
  for_each = local.normal_instances

  ami                    = data.aws_ami.al2023.id
  instance_type          = each.value.instance_type
  key_name               = each.value.key_name
  subnet_id              = var.subnet_id
  vpc_security_group_ids = var.security_group_ids

  root_block_device {
    volume_type = each.value.volume_type
    volume_size = each.value.volume_size
    iops        = each.value.iops
    encrypted   = true
  }

  tags = merge(local.common_tags, { Name = each.key })
}

resource "aws_instance" "protected" {
  for_each = local.protected_instances

  ami                    = data.aws_ami.al2023.id
  instance_type          = each.value.instance_type
  key_name               = each.value.key_name
  subnet_id              = var.subnet_id
  vpc_security_group_ids = var.security_group_ids

  root_block_device {
    volume_type = each.value.volume_type
    volume_size = each.value.volume_size
    iops        = each.value.iops
    encrypted   = true
  }

  tags = merge(local.common_tags, { Name = each.key })

  lifecycle {
    prevent_destroy = true
  }
}
