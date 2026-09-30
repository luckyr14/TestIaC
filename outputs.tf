output "instance_ids" {
  description = "Map of instance name -> instance ID."
  value       = module.ec2_fleet.instance_ids
}

output "private_ips" {
  description = "Map of instance name -> private IP."
  value       = module.ec2_fleet.private_ips
}

output "public_ips" {
  description = "Map of instance name -> public IP (for SSH testing)."
  value       = module.ec2_fleet.public_ips
}

output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnet_id" {
  value = aws_subnet.public.id
}
