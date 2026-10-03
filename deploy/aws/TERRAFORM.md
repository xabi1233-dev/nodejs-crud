# Procedure — putting the EC2 infrastructure under Terraform

Tags: **[LAPTOP]** = your machine, **[AWS]** = the AWS console, **[SERVER]** =
the EC2 instance.

> **Read Part 0 before typing anything.** Your infrastructure already exists and
> was built by hand. That single fact changes the entire procedure, and the
> obvious approach destroys things.

---

## What Terraform does, and what it leaves alone

Terraform manages **the machine and its surroundings**. It does not deploy your
application.

```
Terraform's job          │  Already handled, stays as-is
─────────────────────────┼──────────────────────────────────
EC2 instance             │  App deploy  → .github/workflows/deploy.yml
Security group (ports)   │  Containers  → docker compose
EBS volume (16 GB)       │  TLS cert    → certbot on the box
SSH key pair             │  DNS updates → DuckDNS cron
Elastic IP (optional)    │  Secrets     → .env.docker on the server
```

**`deploy.yml` does not change.** Terraform builds the house; GitHub Actions
keeps moving the furniture in. People conflate these constantly — they are
separate tools solving separate problems, and yours already works.

---

## Part 0 — The fork in the road

Terraform tracks what it manages in a **state file**. Your instance was created
by hand in the console, so that state file is empty: as far as Terraform is
concerned, **your server does not exist.**

Write a config describing a t3.micro and run `terraform apply`, and Terraform
will cheerfully build you a *second* instance. You would then be paying for two
and serving traffic from the old one.

Two honest paths:

| | **A — Import (adopt the running box)** | **B — Greenfield (build a parallel box)** |
|---|---|---|
| Cost | Free | A second instance while you migrate |
| Risk | One careless `apply` hits production | Production untouched while you experiment |
| Downtime | None | A cutover, plus redoing certbot + DuckDNS |
| Teaches you | How real teams adopt legacy infra | How to build from scratch |

**Recommended: A**, but only because of the safety gate in Part 6 — after
importing, `terraform plan` must report **"No changes."** That output is a
genuine proof that your code matches reality, and it is free to obtain.

If the plan ever proposes *destroying* or *replacing* your instance, you stop.
Details in Part 6.

---

## Part 0b — Snapshot first. This is your rollback.

**[AWS]** EC2 → Instances → select the instance → Actions → Image and templates
→ **Create image**. Name it `crud-pre-terraform`.

Or **[LAPTOP]**, once the AWS CLI is set up (Part 1):

```bash
aws ec2 create-image \
  --instance-id i-xxxxxxxxxxxx \
  --name "crud-pre-terraform-$(date +%F)" \
  --description "Snapshot before Terraform import"
```

Takes a few minutes and costs a little storage. If anything in this procedure
goes wrong, you can launch a new instance from that image. Do not skip it —
`terraform destroy` has no undo, and neither does an accidental replace.

---

## Part 1 — Tools and credentials

**[LAPTOP]** Neither tool is currently installed here.

### Terraform — install the official binary, not the apt repo or the snap

> **This laptop is Ubuntu 20.04 (focal), and that rules out the obvious routes.**
>
> - **HashiCorp's apt repo is frozen for focal.** The suite still resolves, but
>   its `Release` file is dated **June 2025** — HashiCorp stopped publishing
>   there when 20.04 left standard support. `$(lsb_release -cs)` would silently
>   point you at a repository a year and a half stale.
> - **`snap install terraform` is published by Snapcrafters, not HashiCorp**,
>   and requires `--classic` — meaning no sandbox, arbitrary system access. A
>   third-party repackage with full system rights, for a tool that is a single
>   static binary, is a poor trade.
>
> Same shape as the NodeSource problem on the server, inverted: there the OS was
> too new for the repo, here it is too old.

HashiCorp ships Terraform as one self-contained binary. Take it directly:

```bash
TF_VERSION=1.16.5
cd /tmp

sudo apt install -y unzip        # not present by default on a minimal 20.04

curl -fsSLO "https://releases.hashicorp.com/terraform/${TF_VERSION}/terraform_${TF_VERSION}_linux_amd64.zip"
curl -fsSLO "https://releases.hashicorp.com/terraform/${TF_VERSION}/terraform_${TF_VERSION}_SHA256SUMS"

# Verify before trusting it. This must print "OK".
sha256sum --check --ignore-missing "terraform_${TF_VERSION}_SHA256SUMS"

unzip -o "terraform_${TF_VERSION}_linux_amd64.zip"
sudo install -m 0755 terraform /usr/local/bin/terraform
rm -f terraform "terraform_${TF_VERSION}"*

terraform version
```

To upgrade later, repeat with a new `TF_VERSION`. To remove it,
`sudo rm /usr/local/bin/terraform` — nothing else is touched.

### AWS CLI — use the v2 installer

Focal's `apt install awscli` gives you **v1.18**, from 2020. Take v2 instead:

```bash
cd /tmp
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip -q -o awscliv2.zip
sudo ./aws/install --update
rm -rf aws awscliv2.zip

aws --version        # expect aws-cli/2.x
```

### Credentials — use `aws login`, not access keys

AWS CLI 2.32.0+ added `aws login`: a browser sign-in that issues **temporary**
credentials, auto-refreshed, valid up to 12 hours. No long-lived key is ever
written to disk.

Prefer it. An access key does not expire — a leaked one stays valid until
somebody notices. A 12-hour session expires on its own.

**[AWS]** IAM → Users → Create user → `terraform-cli`, and this time **do tick
"Provide user access to the AWS Management Console"** — `aws login` signs in
through the console, so this user needs console access.

Attach **two** managed policies:

| Policy | Grants |
|---|---|
| `AmazonEC2FullAccess` | Permission to read and change EC2 resources |
| `SignInLocalDevelopmentAccess` | Permission to exchange a console sign-in for temporary CLI credentials |

Both are required and they do different jobs. The second one only enables the
sign-in flow; it grants no access to any service.

**[LAPTOP]**

```bash
aws --version          # must be >= 2.32.0
aws login              # opens a browser; pick the identity; returns to terminal
aws sts get-caller-identity
```

That last command must print your account ID and the user ARN. If it errors,
stop here — every later step depends on it.

Re-run `aws login` when the session expires. `aws logout` ends it early.

#### If Terraform cannot see those credentials

`aws login` writes a `login_session` profile, and not every SDK understands it
yet. If `terraform plan` fails with *"no valid credential sources found"*, use
the documented bridge — the CLI hands credentials to any tool via
`credential_process`. Edit `~/.aws/config`:

```ini
[default]
login_session = arn:aws:iam::123456789012:user/terraform-cli
region        = eu-north-1

[profile tf]
credential_process = aws configure export-credentials --profile default --format process
region             = eu-north-1
```

Then `export AWS_PROFILE=tf` before running Terraform. The CLI keeps refreshing
the session; Terraform just asks the CLI for current credentials each time.

#### If you use an access key anyway

Still workable — `aws configure`, keys land in `~/.aws/credentials`, outside the
repo. But treat it as the fallback, and never put the key in a `.tf` file, in
the repo, or in a GitHub secret.

---

## Part 2 — Repo layout and `.gitignore`, before you run anything

The state file is written the first time you run `plan` with import blocks, and
**it contains every attribute of your infrastructure in plaintext.** Set the
ignore rules first, not after.

```
infra/
├── versions.tf          # provider + version pins
├── main.tf              # the resources
├── variables.tf
├── terraform.tfvars     # your values — GITIGNORED
└── terraform.tfvars.example
```

Add to `.gitignore`:

```gitignore
# Terraform
infra/.terraform/
*.tfstate
*.tfstate.*
*.tfvars
!*.tfvars.example
crash.log
```

**One deliberate exception: commit `.terraform.lock.hcl`.** It pins provider
versions the way `package-lock.json` pins npm packages. Ignoring it is a common
mistake — it is not a secret and it belongs in the repo.

---

## Part 3 — Find out what you actually have

**[LAPTOP]** Terraform imports by resource ID, so collect them first:

```bash
# Instance, its AMI, type, subnet, and attached security groups
aws ec2 describe-instances \
  --filters "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].{ID:InstanceId,AMI:ImageId,Type:InstanceType,Subnet:SubnetId,SG:SecurityGroups[].GroupId,IP:PublicIpAddress}' \
  --output table

# Security group rules
aws ec2 describe-security-groups \
  --query 'SecurityGroups[?GroupName!=`default`].{Name:GroupName,ID:GroupId}' \
  --output table

# The EBS volume
aws ec2 describe-volumes \
  --query 'Volumes[].{ID:VolumeId,Size:Size,Type:VolumeType,Instance:Attachments[0].InstanceId}' \
  --output table
```

Write the IDs down. You need `i-…`, `sg-…`, `vol-…`.

---

## Part 4 — Pin the provider

`infra/versions.tf`:

```hcl
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
}
```

`infra/variables.tf`:

```hcl
variable "region" {
  description = "AWS region the instance lives in"
  type        = string
  default     = "eu-north-1"   # change to match your instance
}
```

```bash
cd infra
terraform init
```

---

## Part 5 — Import blocks, and let Terraform write the first draft

Modern Terraform (1.5+) uses **`import` blocks** rather than the old
`terraform import` CLI command. They are declarative, reviewable, and — the
useful part — Terraform can generate the configuration for you.

`infra/imports.tf`:

```hcl
import {
  to = aws_instance.crud
  id = "i-xxxxxxxxxxxx"
}

import {
  to = aws_security_group.crud
  id = "sg-xxxxxxxxxxxx"
}
```

Then:

```bash
terraform plan -generate-config-out=generated.tf
```

Terraform reads the live resources and writes its best guess at the HCL into
`generated.tf`.

**Treat that file as a rough draft, not an answer.** Config generation is still
marked experimental, and the output always needs editing:

- it hardcodes IDs that should be references or variables
- it includes read-only attributes Terraform cannot actually set
- it will not generate config for resources using `count` or `for_each`

Move the cleaned-up resources into `main.tf`, delete `generated.tf`, and keep
the `import` blocks until the first successful apply.

---

## Part 6 — The safety gate. Do not skip this.

```bash
terraform plan
```

You are looking for exactly one outcome:

```
No changes. Your infrastructure matches the configuration.
```

**If instead the plan says it will `destroy` or `replace` your instance — stop.**
Do not apply. Something in your config does not match reality, and applying it
deletes your running server.

The two usual culprits, both of which force a **replacement** rather than an
in-place update:

| Attribute | Why it bites |
|---|---|
| `ami` | The generated AMI ID must match exactly what the instance was launched from. A newer Ubuntu AMI means "destroy and rebuild" |
| `user_data` | You never set it by hand, so the config must leave it absent — not empty-string. Any difference forces replacement |

Fix the config until the plan is clean. Only a `plan` that says *No changes* has
proven your code describes your actual infrastructure.

---

## Part 7 — Make one trivial change through Terraform

Now prove the loop works, with something harmless and reversible. Add a tag:

```hcl
resource "aws_instance" "crud" {
  # ...everything from the import...

  tags = {
    Name      = "crud-app"
    ManagedBy = "terraform"
  }
}
```

```bash
terraform plan     # should show ~ 1 to change, 0 to add, 0 to destroy
terraform apply
```

If that applies cleanly, Terraform is genuinely in control and you can start
managing the security group, volume size and so on through code.

---

## Part 8 — Worth doing while you are here: the Elastic IP

A fact that undermines one of your earlier decisions.

Since **1 February 2024** AWS charges **$0.005/hour for every public IPv4
address — including ones attached to a running instance** (~$3.60/month). Before
that date, in-use addresses were free and only idle Elastic IPs cost money.

You chose DuckDNS over an Elastic IP to avoid a charge. **You are already paying
that charge** on the auto-assigned IP. An Elastic IP would cost you the same.

(If your account is still inside the 12-month free tier, 750 hours/month of
in-use public IPv4 is covered — which is one address running continuously.
Either way, EIP and auto-assigned cost the same.)

So in Terraform:

```hcl
resource "aws_eip" "crud" {
  instance = aws_instance.crud.id
  domain   = "vpc"
}
```

A fixed IP means the DuckDNS updater has nothing left to update. Keep the
hostname — it is what the TLS certificate is issued for — but the 5-minute cron
job and `duckdns-update.sh` become dead weight you can retire.

**Check your own bill before acting on this.** Cost Explorer → filter on
`Public IPv4 Address` usage type.

---

## Part 9 — State: where it lives and why it matters

By default `terraform.tfstate` sits in `infra/` on your laptop. For a solo
project that is acceptable, with two caveats:

1. **It contains secrets in plaintext.** Not just passwords — every attribute of
   every resource. This is why Part 2 gitignores it.
2. **Lose it and Terraform forgets it manages anything.** Your infrastructure
   keeps running, but Terraform would try to recreate it all from scratch.
   Back it up somewhere that is not the repo.

The grown-up answer is a remote backend — S3 with versioning for storage and
state locking so two applies cannot race:

```hcl
terraform {
  backend "s3" {
    bucket       = "your-unique-tfstate-bucket"
    key          = "crud/terraform.tfstate"
    region       = "eu-north-1"
    encrypt      = true
    use_lockfile = true    # S3-native locking; DynamoDB no longer required
  }
}
```

Costs pennies a month. Worth doing before anyone else touches this.

---

## Part 10 — Should Terraform run in CI?

**Not yet.** `terraform apply` in GitHub Actions needs AWS credentials with
power to create and destroy infrastructure. Your current deploy secrets can only
SSH to one box; these could delete your account's resources. Different blast
radius entirely.

Sensible progression later:

1. `terraform plan` on pull requests, posting the diff as a comment — read-only,
   safe, and genuinely useful for review
2. `terraform apply` only on manual dispatch, with OIDC federation instead of
   long-lived keys
3. Never an automatic apply on push

Run it from your laptop until the plan loop is second nature.

---

## What stays out of Terraform entirely

| Thing | Why |
|---|---|
| Let's Encrypt cert | certbot owns it on the box; renewal is a systemd timer |
| DuckDNS | Third-party service, no Terraform provider |
| App deployment | `deploy.yml` already does this well |
| `.env.docker` | Server-only secrets; Terraform state would expose them |
| Docker images | Built on the server by `deploy-docker.sh` |

Terraform describes the machine. Everything above describes what runs on it.

---

## Order of work

1. Snapshot the instance (Part 0b) — **do not skip**
2. Install Terraform + AWS CLI, verify `aws sts get-caller-identity`
3. `.gitignore` entries *before* the first run
4. Collect resource IDs
5. `terraform init`, import blocks, `-generate-config-out`
6. Clean up the generated config until `plan` says **No changes**
7. One trivial change (a tag) to prove the loop
8. Then: Elastic IP, remote state, and retiring the DuckDNS cron

Steps 1–4 are an evening. Step 6 is where the real learning is, and where you
should expect to spend the most time.

---

Sources: [Terraform import blocks and config generation](https://spacelift.io/learn/terraform-import-generate-configuration),
[AWS public IPv4 address charge](https://aws.amazon.com/blogs/aws/new-aws-public-ipv4-address-charge-public-ip-insights).
