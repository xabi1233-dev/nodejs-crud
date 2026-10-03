# Input variables.
#
# The resource IDs live here rather than inline in imports.tf for one reason:
# this repository is PUBLIC. Instance and security-group IDs are not secrets in
# the way a password is, but they do describe your account's layout and there is
# no reason to publish them. Real values go in terraform.tfvars, which is
# gitignored; terraform.tfvars.example carries the placeholders.
#
# Import blocks accept "a string or an expression that evaluates to a string",
# so variables are valid there.

variable "region" {
  description = "AWS region the existing instance lives in, e.g. eu-north-1"
  type        = string

  # No default on purpose. A wrong region does not error — it silently looks at
  # an empty region and proposes creating everything from scratch. Setting it
  # explicitly makes that mistake impossible.
}

variable "instance_id" {
  description = "ID of the running EC2 instance to import, e.g. i-0abc123..."
  type        = string

  validation {
    condition     = can(regex("^i-[0-9a-f]{8,}$", var.instance_id))
    error_message = "instance_id must look like i-0abc123def456789."
  }
}

variable "security_group_id" {
  description = "ID of the instance's security group, e.g. sg-0abc123..."
  type        = string

  validation {
    condition     = can(regex("^sg-[0-9a-f]{8,}$", var.security_group_id))
    error_message = "security_group_id must look like sg-0abc123def456789."
  }
}

variable "instance_name" {
  description = "Value for the instance's Name tag"
  type        = string

  # Must match the tag the instance already carries, or the first plan after
  # import would show "1 to change" instead of a clean zero.
  default = "NodejsCRUD"
}
