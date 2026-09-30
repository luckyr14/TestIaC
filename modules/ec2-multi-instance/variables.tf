variable "ami" {
  description = "AMI ID to use for all instances. Passed in from root so it can come from a data source."
  type        = string
}

variable "instances" {
  description = "Map of instance name -> config. Key becomes the Name tag."
  type = map(object({
    instance_type    = string
    root_volume_type = string
    root_volume_size = number
    iops             = optional(number, null) # required for io1/io2, optional for gp3, ignored for gp2
    key_pair         = optional(string, null)
  }))
}

variable "protected_instance" {
  description = "Key in var.instances that gets prevent_destroy = true."
  type        = string
}

variable "subnet_id" {
  description = "Subnet to launch all instances into."
  type        = string
}

variable "security_group_ids" {
  description = "Security groups to attach to every instance."
  type        = list(string)
  default     = []
}

variable "environment" {
  type = string
}

variable "owner" {
  type = string
}
