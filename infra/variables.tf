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

# --- Rebuild-from-scratch inputs --------------------------------------------
# Consumed by user_data.sh via templatefile(). Changing any of these changes
# user_data, and user_data_replace_on_change makes that REPLACE the instance.

variable "repo_url" {
  description = "HTTPS clone URL of the application repository"
  type        = string
  default     = "https://github.com/xabi1233-dev/nodejs-crud.git"
}

variable "duckdns_domain" {
  description = "DuckDNS subdomain WITHOUT the .duckdns.org suffix, e.g. isdi-crud"
  type        = string
  default     = "isdi-crud"
}

variable "duckdns_token" {
  description = "DuckDNS API token. Leave empty to skip DNS and TLS setup."
  type        = string
  default     = ""
  sensitive   = true

  # `sensitive` only stops Terraform PRINTING it. The token is still stored in
  # plaintext in terraform.tfstate, and it is readable from the instance's
  # metadata service by anything running on the box, because user_data is not
  # encrypted.
  #
  # Acceptable for a DuckDNS token, which is free and revocable in one click.
  # It would NOT be acceptable for a database or cloud credential. The proper
  # fix is SSM Parameter Store with an IAM instance profile — which needs IAM
  # permissions your terraform-cli user does not currently have.
}

variable "certbot_email" {
  description = "Contact address for Let's Encrypt expiry notices"
  type        = string
  default     = ""
}

variable "certbot_staging" {
  description = "Use Let's Encrypt staging. Keep true while iterating."
  type        = bool

  # Let's Encrypt allows 5 certificates per domain per week. A destroy/apply
  # loop exhausts that in an afternoon, and then issues nothing for days.
  # Staging certs are untrusted by browsers but free and effectively unlimited.
  default = true
}

variable "deploy_public_key" {
  description = "Public half of the GitHub Actions deploy key (~/.ssh/crud-deploy.pub). Empty disables auto-deploy after a rebuild."
  type        = string
  default     = ""
}

# --- Throwaway test instance (scratch.tf) -----------------------------------

variable "scratch_enabled" {
  description = "Build the disposable user_data test instance"
  type        = bool
  default     = false

  # Off by default so `terraform apply` with no arguments always tears it down.
  # Turn it on per-command: terraform apply -var="scratch_enabled=true"
}

variable "scratch_ssh_cidr" {
  description = "CIDR allowed to SSH to the scratch box. Narrow this to your own IP: curl -s ifconfig.me"
  type        = string
  default     = "0.0.0.0/0"
}

variable "scratch_duckdns_domain" {
  description = "A SEPARATE DuckDNS subdomain for the scratch box. NEVER your production one."
  type        = string
  default     = ""

  validation {
    condition     = var.scratch_duckdns_domain != var.duckdns_domain || var.scratch_duckdns_domain == ""
    error_message = "scratch_duckdns_domain must differ from duckdns_domain. The scratch instance runs duckdns-update.sh, which would repoint your live domain at the throwaway box and take the real site down."
  }
}

variable "scratch_duckdns_token" {
  description = "DuckDNS token for the scratch subdomain. Empty (default) skips DNS and TLS entirely — plain HTTP on the public IP."
  type        = string
  default     = ""
  sensitive   = true
}
