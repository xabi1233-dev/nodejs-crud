# Terraform and provider version pinning.
#
# `required_version` guards against someone running this with an older CLI that
# lacks import blocks (added in 1.5). `~> 6.0` on the provider means "any 6.x,
# no 7.x" — major versions of the AWS provider carry breaking changes.
#
# After `terraform init`, commit .terraform.lock.hcl. It pins the exact provider
# build the way package-lock.json pins npm packages. It is not a secret.

terraform {
  required_version = ">= 1.16"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.region

  # DELIBERATELY NOT SET YET — see the warning below.
  #
  # default_tags {
  #   tags = {
  #     Project   = "crud"
  #     ManagedBy = "terraform"
  #   }
  # }
  #
  # default_tags applies tags to every resource the provider manages. Switch it
  # on now and your imported instance would come back from `terraform plan` as
  # "1 to change" — because it does not carry those tags yet.
  #
  # That would destroy the one signal the import procedure depends on: a plan
  # that says "No changes." Leave this commented until that clean plan is in
  # hand, then enable it as the deliberate first change (Part 7 of TERRAFORM.md).
}
