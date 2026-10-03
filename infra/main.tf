# The live EC2 infrastructure, adopted from the hand-built instance.
#
# Originally produced by `terraform plan -generate-config-out=generated.tf`,
# then cleaned up. Changes made to the generated draft:
#
#   - removed `tags_all` (computed by the provider; not settable in config)
#   - removed `ipv6_address_count` / `ipv6_addresses` (mutually exclusive, and
#     both empty — this instance has no IPv6)
#   - removed the `primary_network_interface` block (conflicts with
#     associate_public_ip_address; the ENI is implied by subnet + SG)
#   - replaced the hardcoded security group ID with a resource reference
#   - moved the Name tag to var.instance_name
#   - added lifecycle.prevent_destroy to the instance
#
# Everything else is verbatim from the live resources, which is why
# `terraform plan` reports no changes.

resource "aws_security_group" "crud" {
  name        = "launch-wizard-1"
  description = "launch-wizard-1 created 2026-09-17T14:32:29.493Z"
  vpc_id      = "vpc-0a184be54b3305e57"
  region      = "eu-north-1"

  revoke_rules_on_delete = null
  tags                   = {}

  # NOTE: port 3000 is deliberately absent and must stay that way. nginx is the
  # only public entry point; Docker publishes the app on 127.0.0.1 so it cannot
  # be reached directly. See deploy/aws/EC2-DOCKER.md.
  #
  # SSH is open to 0.0.0.0/0 here. That is how the instance was built, and it is
  # recorded faithfully so the plan stays clean — but it is worth narrowing to
  # your own IP as a deliberate, separate change.
  ingress = [{
    cidr_blocks      = ["0.0.0.0/0"]
    description      = ""
    from_port        = 22
    ipv6_cidr_blocks = []
    prefix_list_ids  = []
    protocol         = "tcp"
    security_groups  = []
    self             = false
    to_port          = 22
    }, {
    cidr_blocks      = ["0.0.0.0/0"]
    description      = ""
    from_port        = 443
    ipv6_cidr_blocks = []
    prefix_list_ids  = []
    protocol         = "tcp"
    security_groups  = []
    self             = false
    to_port          = 443
    }, {
    cidr_blocks      = ["0.0.0.0/0"]
    description      = ""
    from_port        = 80
    ipv6_cidr_blocks = []
    prefix_list_ids  = []
    protocol         = "tcp"
    security_groups  = []
    self             = false
    to_port          = 80
  }]

  egress = [{
    cidr_blocks      = ["0.0.0.0/0"]
    description      = ""
    from_port        = 0
    ipv6_cidr_blocks = []
    prefix_list_ids  = []
    protocol         = "-1"
    security_groups  = []
    self             = false
    to_port          = 0
  }]
}

resource "aws_instance" "crud" {
  # Pinned to the exact AMI this instance was launched from. Do NOT swap in a
  # data "aws_ami" lookup for "newest Ubuntu" — the next Canonical release
  # would make Terraform plan to destroy and rebuild the server.
  ami           = "ami-0aba19e56f3eaec05"
  instance_type = "t3.micro"
  key_name      = "x"

  availability_zone = "eu-north-1a"
  subnet_id         = "subnet-09319e1fb8dfbf677"
  private_ip        = "172.31.28.250"
  region            = "eu-north-1"

  associate_public_ip_address = true
  source_dest_check           = true
  # `security_groups` (group NAMES) is the EC2-Classic attribute. In a VPC,
  # RunInstances requires group IDs, so passing a name here fails the CREATE
  # with InvalidGroup.NotFound — even though it reads back fine on an
  # already-running instance, which is why `terraform plan` showed no changes.
  # Only vpc_security_group_ids is correct for a VPC instance.
  vpc_security_group_ids = [aws_security_group.crud.id]

  # --- REBUILD-FROM-SCRATCH MODE: ENABLED -----------------------------------
  #
  # This instance now provisions itself from user_data.sh on first boot.
  #
  # user_data_replace_on_change = true means ANY edit to user_data.sh destroys
  # and recreates this instance. That is required — a first-boot script that
  # only runs on first boot is useless otherwise — but it makes editing that
  # file an expensive operation, never a quick tweak.
  #
  # Replacement DESTROYS THE DISK (root_block_device.delete_on_termination).
  # The MySQL volume, .env.docker, the TLS certificate and /etc/duckdns.conf
  # all go with it. The script recreates all of those EXCEPT the data: MySQL
  # comes back seeded from schema.sql, not from your rows.
  #
  # Always `terraform plan` and read it before applying.
  user_data = templatefile("${path.module}/user_data.sh", {
    repo_url          = var.repo_url
    duckdns_domain    = var.duckdns_domain
    duckdns_token     = var.duckdns_token
    certbot_email     = var.certbot_email
    certbot_staging   = tostring(var.certbot_staging)
    deploy_public_key = var.deploy_public_key
  })
  user_data_replace_on_change = true

  disable_api_stop                     = false
  disable_api_termination              = false
  ebs_optimized                        = true
  force_destroy                        = false
  get_password_data                    = false
  hibernation                          = false
  instance_initiated_shutdown_behavior = "stop"
  monitoring                           = false
  placement_partition_number           = 0
  secondary_private_ips                = []
  tenancy                              = "default"
  volume_tags                          = null

  tags = {
    Name = var.instance_name
  }

  capacity_reservation_specification {
    capacity_reservation_preference = "open"
  }

  cpu_options {
    core_count       = 1
    threads_per_core = 2
  }

  credit_specification {
    cpu_credits = "unlimited"
  }

  enclave_options {
    enabled = false
  }

  maintenance_options {
    auto_recovery = "default"
  }

  # http_tokens = "required" means IMDSv2 only — the metadata service refuses
  # unauthenticated requests. This is what the DuckDNS updater script uses to
  # read the public IP, and why that script fetches a token first.
  metadata_options {
    http_endpoint               = "enabled"
    http_protocol_ipv6          = "disabled"
    http_put_response_hop_limit = 2
    http_tokens                 = "required"
    instance_metadata_tags      = "disabled"
  }

  private_dns_name_options {
    enable_resource_name_dns_a_record    = true
    enable_resource_name_dns_aaaa_record = false
    hostname_type                        = "ip-name"
  }

  # 16 GB, grown from the original 6.9 GB when Docker ran out of room.
  root_block_device {
    delete_on_termination = true
    encrypted             = false
    iops                  = 3000
    tags                  = {}
    throughput            = 125
    volume_size           = 16
    volume_type           = "gp3"
  }

  # prevent_destroy was REMOVED deliberately on 2026-10-03 to allow the
  # rebuild-from-code workflow above. This instance is now disposable by
  # design: `terraform destroy` will delete it, and `terraform apply` will
  # build a replacement that provisions itself.
  #
  # Nothing now stands between a mistyped command and the loss of this server.
  # The backup discipline in deploy/aws/TERRAFORM.md is the only safety net.
  #
  # To make it protected again, restore:
  #
  #   lifecycle {
  #     prevent_destroy = true
  #   }
}
