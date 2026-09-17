# Deploying the CRUD app to AWS EC2

Target architecture — identical in shape to the local setup, with Nginx in
Apache's place:

```
browser → Nginx :80 (EC2 public IP) → Node/Express :3000 → MySQL (same instance)
```

Everything except the console clicks is automated by `provision.sh`.

---

## Part 1 — Create the instance (AWS Console)

### 1.1 Pick a region

Top-right region selector. Use **Asia Pacific (Mumbai) `ap-south-1`** for lowest
latency from Pakistan. Whatever you choose, stay in it — instances, key pairs and
security groups are all region-scoped, and a key pair created in one region is
invisible in another.

### 1.2 Launch

EC2 → **Instances** → **Launch instances**.

| Field | Value |
|---|---|
| Name | `crud-app` |
| AMI | **Ubuntu Server 24.04 LTS (64-bit x86)** — confirm the "Free tier eligible" tag |
| Instance type | `t3.micro` (or `t2.micro` if that's what your account's free tier offers) |
| Key pair | **Create new key pair** → name `crud-key`, type **RSA**, format **.pem** → Download |
| Storage | 1 × **16 GiB gp3** (free tier allows up to 30 GiB) |

The `.pem` downloads **once**. Lose it and you lose SSH access to this instance —
there is no way to re-download it.

### 1.3 Network settings

Click **Edit** on the Network settings panel. Create a security group named
`crud-sg` with exactly two inbound rules:

| Type | Port | Source | Why |
|---|---|---|---|
| SSH | 22 | **My IP** | Admin access, restricted to your address |
| HTTP | 80 | Anywhere `0.0.0.0/0` | Public web traffic |

**Do not open port 3000.** Node listens only on `127.0.0.1`, and Nginx is the sole
public entry point. Exposing 3000 would bypass Nginx entirely.

**Do not set SSH to "Anywhere".** That invites constant brute-force traffic. If your
home IP changes, edit the rule later — it takes ten seconds.

### 1.4 Launch and collect the IP

**Launch instance**, wait for *Instance state: Running* and both status checks to
pass (~1 minute). Copy the **Public IPv4 address** from the instance detail page.

> That IP changes on every stop/start. If you need a stable address, allocate an
> Elastic IP (free while attached to a running instance) and associate it.

---

## Part 2 — Deploy (from your laptop)

### 2.1 Secure the key

```bash
mv ~/Downloads/crud-key.pem ~/.ssh/
chmod 400 ~/.ssh/crud-key.pem
```

`chmod 400` is required — SSH refuses keys readable by anyone else.

### 2.2 Verify SSH works

```bash
ssh -i ~/.ssh/crud-key.pem ubuntu@<PUBLIC-IP>
```

Accept the host fingerprint. You should land at `ubuntu@ip-...:~$`. Type `exit`.

If it hangs, your security group's SSH source doesn't match your current IP.

### 2.3 Upload and provision

From the project root:

```bash
cd /var/www/your_domain/crud
bash deploy/aws/upload.sh <PUBLIC-IP> ~/.ssh/crud-key.pem
```

Answer `y` when it offers to provision. Takes 3–5 minutes and installs Node.js 20,
MySQL 8, Nginx, a 2 GB swapfile, the systemd service and the Nginx site, then
applies the schema and runs a health check.

The database password is generated on the server, not copied from your local
`.env`. It's saved to `/home/ubuntu/.crud_db_password`.

### 2.4 Open it

```
http://<PUBLIC-IP>
```

Browsers may force HTTPS on a bare IP — type `http://` explicitly if it fails.

---

## Operating the server

```bash
ssh -i ~/.ssh/crud-key.pem ubuntu@<PUBLIC-IP>

sudo systemctl status crud        # is the app up
journalctl -u crud -f             # live app logs
sudo systemctl restart crud       # restart after changes
sudo tail -f /var/log/nginx/crud_error.log

mysql -u crud_user -p"$(cat ~/.crud_db_password)" crud_db -e "SELECT * FROM users;"
```

### Redeploying code

Re-run the same upload script and answer `y`:

```bash
bash deploy/aws/upload.sh <PUBLIC-IP> ~/.ssh/crud-key.pem
```

`provision.sh` is idempotent — it reuses the existing database and password, and
only refreshes files, dependencies and services.

---

## Troubleshooting

| Symptom | Cause |
|---|---|
| Browser times out | Security group is missing the HTTP :80 rule |
| **502 Bad Gateway** | Nginx is up, Node is not — `sudo systemctl status crud` |
| SSH `Permission denied (publickey)` | Wrong user (it's `ubuntu`, not `root`/`ec2-user`) or key not `chmod 400` |
| SSH hangs | Your IP changed; update the SSH rule's source |
| `provision.sh` fails on npm | Out of RAM — the script adds swap, so re-run it |
| App up but 500 errors | DB issue — `journalctl -u crud -n 50` |

---

## Cost

Within the 12-month free tier: 750 hours/month of `t3.micro` plus 30 GB storage
covers one instance running continuously at no cost. After it expires, roughly
$8–10/month. **Terminate the instance** (not just stop it) when you're done
experimenting — stopped instances still bill for their EBS volume.

## Security note

This is a deliberately minimal deployment: plain HTTP, no authentication on the
CRUD pages, and anyone with the IP can add or delete users. Fine for a learning
exercise on a throwaway instance. Before it holds anything real, it needs at
minimum TLS (certbot + a domain), authentication, and CSRF protection on the
mutating routes.
