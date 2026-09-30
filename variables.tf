variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "project" {
  description = "Short name used in resource name tags."
  type        = string
  default     = "infra-code"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "owner" {
  type    = string
  default = "platform-team"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  type    = string
  default = "10.0.1.0/24"
}

variable "ssh_allowed_cidr" {
  description = "CIDR allowed to SSH. Use your own IP (x.x.x.x/32) in production."
  type        = string
  default     = "0.0.0.0/0"
}

variable "instances" {
  description = "Map of instance name -> config. All 5 instances are driven from this single variable."
  type = map(object({
    instance_type    = string
    root_volume_type = string
    root_volume_size = number
    iops             = optional(number, null)
    key_pair         = optional(string, null)
  }))
}
