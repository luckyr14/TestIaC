output "instance_ids" {
  description = "Map of instance name -> instance ID."
  value = merge(
    { for k, v in aws_instance.standard : k => v.id },
    { for k, v in aws_instance.protected : k => v.id },
  )
}

output "private_ips" {
  description = "Map of instance name -> private IP."
  value = merge(
    { for k, v in aws_instance.standard : k => v.private_ip },
    { for k, v in aws_instance.protected : k => v.private_ip },
  )
}

output "public_ips" {
  description = "Map of instance name -> public IP (useful for SSH during testing)."
  value = merge(
    { for k, v in aws_instance.standard : k => v.public_ip },
    { for k, v in aws_instance.protected : k => v.public_ip },
  )
}
