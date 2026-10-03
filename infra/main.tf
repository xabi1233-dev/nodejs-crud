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
  security_groups             = ["launch-wizard-1"]
  vpc_security_group_ids      = [aws_security_group.crud.id]

  # Absent, not empty-string. The instance was built by hand with no user_data,
  # and `user_data = ""` would differ from null — a difference that forces
  # replacement rather than an in-place update.
  user_data                   = null
  user_data_replace_on_change = null

  # --- REBUILD-FROM-SCRATCH MODE (currently disabled) -----------------------
  #
  # Replace the two `null` lines above with the block below to make this
  # instance rebuild itself from code on every boot.
  #
  # READ THIS BEFORE UNCOMMENTING.
  #
  # This instance was imported, and it currently has user_data = null. Setting
  # user_data to a script CHANGES AN ATTRIBUTE THAT FORCES REPLACEMENT. The
  # plan will read:
  #
  #     # aws_instance.crud must be replaced
  #     -/+ destroy and then create replacement
  #
  # Because root_block_device.delete_on_termination = true, replacement
  # DESTROYS THE DISK. You lose the MySQL volume and every user row in it,
  # .env.docker, the Let's Encrypt certificate and /etc/duckdns.conf.
  #
  # The lifecycle.prevent_destroy block at the bottom of this resource will
  # refuse the plan until you remove it. That is deliberate.
  #
  # To switch over, in this order:
  #   1. Back up the data, from the SERVER:
  #        cd /var/www/crud
  #        docker compose --env-file .env.docker exec -T db \
  #          mysqldump -u root -p"$(grep MYSQL_ROOT_PASSWORD .env.docker | cut -d= -f2)" \
  #          crud_db > ~/final_backup.sql
  #      then scp it to your laptop.
  #   2. Confirm the AMI snapshot is `available`.
  #   3. Fill duckdns_token, certbot_email and deploy_public_key in
  #      terraform.tfvars. Leave certbot_staging = true.
  #   4. Delete the lifecycle.prevent_destroy block below — as its own commit.
  #   5. Swap the two null lines above for this block.
  #   6. terraform plan, and read every line of it.
  #   7. terraform apply, then wait ~4 minutes and watch
  #        ssh ... 'sudo tail -f /var/log/cloud-init-output.log'
  #   8. Restore the dump if you want the old rows back.
  #
  # user_data_replace_on_change = true means every later EDIT to user_data.sh
  # also replaces the instance. That is the intended behaviour — a first-boot
  # script that only runs on first boot is useless otherwise — but it means
  # editing that file is never a cheap change.
  #
  # user_data = templatefile("${path.module}/user_data.sh", {
  #   repo_url          = var.repo_url
  #   duckdns_domain    = var.duckdns_domain
  #   duckdns_token     = var.duckdns_token
  #   certbot_email     = var.certbot_email
  #   certbot_staging   = tostring(var.certbot_staging)
  #   deploy_public_key = var.deploy_public_key
  # })
  # user_data_replace_on_change = true

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

  # Refuse to destroy this instance, even if a future config change would
  # otherwise require replacing it. Remove this deliberately if you ever do
  # intend to rebuild the box.
  lifecycle {
    prevent_destroy = true
  }
}
