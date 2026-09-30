# lifecycle meta-arguments cannot reference dynamic values (evaluated at plan time
# before any expressions resolve), so we split the map into two resources:
# one for standard instances and one for the single protected instance.
locals {
  standard_instances  = { for k, v in var.instances : k => v if k != var.protected_instance }
  protected_instances = { for k, v in var.instances : k => v if k == var.protected_instance }
}

resource "aws_instance" "standard" {
  for_each                    = local.standard_instances
  ami                         = var.ami
  instance_type               = each.value.instance_type
  key_name                    = each.value.key_pair
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = var.security_group_ids
  associate_public_ip_address = true

  root_block_device {
    volume_type = each.value.root_volume_type
    volume_size = each.value.root_volume_size
    # iops is valid for io1, io2, and gp3; null means "use default" for others
    iops = contains(["io1", "io2"], each.value.root_volume_type) ? coalesce(each.value.iops, 100) : null
  }

  tags = {
    Name        = each.key
    Environment = var.environment
    Owner       = var.owner
  }
}

resource "aws_instance" "protected" {
  for_each                    = local.protected_instances
  ami                         = var.ami
  instance_type               = each.value.instance_type
  key_name                    = each.value.key_pair
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = var.security_group_ids
  associate_public_ip_address = true

  root_block_device {
    volume_type = each.value.root_volume_type
    volume_size = each.value.root_volume_size
    iops        = contains(["io1", "io2"], each.value.root_volume_type) ? coalesce(each.value.iops, 100) : null
  }

  tags = {
    Name        = each.key
    Environment = var.environment
    Owner       = var.owner
  }

  lifecycle {
    prevent_destroy = true
  }
}
