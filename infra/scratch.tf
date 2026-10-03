# Throwaway instance for testing user_data.sh.
#
# Exists so you can find the bugs in a first-boot script on a box that does not
# matter. First-boot scripts always have a couple, and the production path to
# discovering them is "destroy the live server and hope".
#
# Everything here is gated behind scratch_enabled, which defaults to false, so
# this file is inert until you ask for it.
#
#   terraform apply -var="scratch_enabled=true"     # build it  (~4 min)
#   terraform output scratch_ssh                    # how to get in
#   terraform apply                                 # tear it down again
#
# Deliberately NO lifecycle.prevent_destroy — destroying this is the point.
#
# ---------------------------------------------------------------------------
# COST: a t3.micro plus one public IPv4, roughly $0.02/hour. Destroy it when
# you are done. `terraform apply` with no -var does that, because
# scratch_enabled returns to its false default.
# ---------------------------------------------------------------------------

resource "aws_security_group" "scratch" {
  count = var.scratch_enabled ? 1 : 0

  name        = "crud-scratch-delete-me"
  description = "Throwaway SG for user_data testing"
  vpc_id      = "vpc-0a184be54b3305e57"
  region      = var.region

  tags = {
    Name      = "crud-scratch"
    Ephemeral = "true"
  }

  ingress = [{
    cidr_blocks      = [var.scratch_ssh_cidr]
    description      = "SSH for debugging cloud-init"
    from_port        = 22
    ipv6_cidr_blocks = []
    prefix_list_ids  = []
    protocol         = "tcp"
    security_groups  = []
    self             = false
    to_port          = 22
    }, {
    cidr_blocks      = ["0.0.0.0/0"]
    description      = "HTTP"
    from_port        = 80
    ipv6_cidr_blocks = []
    prefix_list_ids  = []
    protocol         = "tcp"
    security_groups  = []
    self             = false
    to_port          = 80
    }, {
    cidr_blocks      = ["0.0.0.0/0"]
    description      = "HTTPS"
    from_port        = 443
    ipv6_cidr_blocks = []
    prefix_list_ids  = []
    protocol         = "tcp"
    security_groups  = []
    self             = false
    to_port          = 443
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

resource "aws_instance" "scratch" {
  count = var.scratch_enabled ? 1 : 0

  # Same AMI, type and subnet as production, so the test is faithful.
  ami           = "ami-0aba19e56f3eaec05"
  instance_type = "t3.micro"
  key_name      = "x"
  subnet_id     = "subnet-09319e1fb8dfbf677"
  region        = var.region

  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.scratch[0].id]

  # The whole point: run the real script, unmodified.
  #
  # DANGER — scratch_duckdns_domain must NOT be your production subdomain.
  # user_data.sh runs duckdns-update.sh, which repoints that name at whatever
  # instance it runs on. Pass your live domain here and this throwaway box
  # hijacks DNS for the real site.
  #
  # The default is an empty token, which makes the script skip DuckDNS and
  # certbot entirely and serve plain HTTP on the public IP. Safe, and enough to
  # test stages 0-5 and 7.
  user_data = templatefile("${path.module}/user_data.sh", {
    repo_url          = var.repo_url
    duckdns_domain    = var.scratch_duckdns_domain
    duckdns_token     = var.scratch_duckdns_token
    certbot_email     = var.certbot_email
    certbot_staging   = "true" # never a real cert on a throwaway box
    deploy_public_key = var.deploy_public_key
  })
  user_data_replace_on_change = true

  root_block_device {
    volume_size           = 16
    volume_type           = "gp3"
    delete_on_termination = true
  }

  # Matches production, and makes the DuckDNS updater's IMDSv2 token fetch
  # behave the same way here as it does there.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  tags = {
    Name      = "crud-scratch-delete-me"
    Ephemeral = "true"
  }
}
