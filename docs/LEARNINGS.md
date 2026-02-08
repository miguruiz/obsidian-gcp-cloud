# ☁️ Understanding Obsidian GCP Vault: Your Cloud Setup

*A deep dive into how this whole thing works, why we built it this way, and what you can learn from it.*

---

## The Big Picture: What Are We Even Doing Here?

Imagine you have notes in Obsidian on your laptop. You also have Obsidian on your phone, your work computer, and maybe a tablet. You want all of them to have the same notes, updated in real-time, without trusting a third-party cloud service with your private thoughts.

**The solution**: Run your own database server (CouchDB) in the cloud, and let Obsidian's LiveSync plugin handle the synchronization. CouchDB is perfect for this because it was literally designed for multi-master replication—the exact thing you need when multiple devices might edit the same note.

**But wait, cloud servers cost money!** Not if you're clever. Google Cloud has an "always-free tier" that includes one tiny VM per month. We're going to use that.

**And managing servers is annoying!** That's why we use Terraform (infrastructure-as-code) and GitHub Actions (automated deployments). Write the config once, push to git, and everything deploys automatically.

---

## The Architecture: A Map of the Territory

```
Your Devices                     GitHub                              Google Cloud
============                     ======                              ============

┌──────────┐                  ┌─────────────┐                    ┌──────────────────┐
│ Laptop   │                  │             │   (1) Push code    │   GCP Project    │
│ Obsidian │                  │  Your Repo  │─────────────────▶ │                  │
└────┬─────┘                  │  (main.tf)  │                    │  ┌────────────┐  │
     │                        │             │                    │  │ e2-micro   │  │
     │                        └──────┬──────┘                    │  │    VM      │  │
     │                               │                           │  │            │  │
     │    ┌──────────────────────────┘                          │  │ ┌────────┐ │  │
     │    │    (2) GitHub Actions                                │  │ │CouchDB │ │  │
     │    │        triggers                                      │  │ │:5984   │ │  │
     │    ▼                                                      │  │ └────────┘ │  │
     │  ┌─────────────────────┐                                  │  └────────────┘  │
     │  │ Workload Identity   │   (3) "Hey GCP, I'm              │         ▲        │
     │  │ Federation (OIDC)   │────── GitHub, let me in"         │         │        │
     │  └─────────────────────┘                                  │         │        │
     │                                                           │         │        │
     │                          (4) Terraform creates/updates    │         │        │
     │                              the VM and firewall          │         │        │
     │                                                           └─────────┼────────┘
     │                                                                     │
     └─────────────────────────────────────────────────────────────────────┘
                        (5) Obsidian syncs notes via CouchDB
```

---

## Technical Deep Dive: The Files and What They Do

### The Terraform Files: Infrastructure as Code

Think of Terraform files as a **blueprint for your cloud infrastructure**. Instead of clicking around in GCP's web console (which is tedious and error-prone), you write what you want in code.

#### `main.tf` - The Heart of It All

This file contains the actual resources we're creating:

**1. Firewall Rules**
```hcl
resource "google_compute_firewall" "allow_couchdb" {
  name    = "allow-couchdb-5984"
  ...
  allow {
    protocol = "tcp"
    ports    = ["5984"]
  }
  source_ranges = var.allowed_ips  # WHO can connect
  target_tags   = ["couchdb-server"]  # WHICH VMs this applies to
}
```

Think of this as telling GCP: "Create a firewall rule that lets certain IP addresses connect to port 5984 on any VM tagged as 'couchdb-server'."

**2. The VM Instance**
```hcl
resource "google_compute_instance" "obsidian_couchdb_vm" {
  name         = "obsidian-couchdb-vm"
  machine_type = "e2-micro"  # The free tier size
  zone         = var.zone

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
      size  = 30  # GB, max for free tier
    }
  }

  metadata_startup_script = <<-SCRIPT
    # This runs when the VM first boots!
    apt-get update
    # Install Docker...
    # Run CouchDB container...
  SCRIPT
}
```

This is where we define the actual virtual machine. The `metadata_startup_script` is **crucial**—it's a bash script that runs automatically when the VM starts up.

#### Why a Startup Script Instead of a Dockerfile?

Great question! Here's the mental model:

- **Dockerfile**: A recipe for building a container image. Used when you're creating reusable container images.
- **Startup Script**: Commands that run when a VM boots. Used when you need to set up a VM from scratch.

We're using a **plain Debian VM**, not a container-optimized image. When GCP creates this VM, it's just a fresh Debian installation—no Docker, no nothing. The startup script:

1. Installs Docker
2. Pulls the CouchDB container image
3. Runs the container with our configuration

**Alternative approach**: GCP has "Container-Optimized OS" (COS) where you can declare a container in metadata and it runs automatically. But COS is limited—you can't easily install additional tools like Tailscale. The startup script approach is more flexible.

#### `variables.tf` - The Configuration Knobs

```hcl
variable "couchdb_password" {
  description = "Admin password for CouchDB"
  type        = string
  sensitive   = true  # This magic word hides it from logs!
}
```

Variables are like function parameters for your infrastructure. They let you customize the deployment without changing the core logic.

The `sensitive = true` flag is important—it tells Terraform to **never show this value in logs or output**. Security matters!

#### `outputs.tf` - The Results

```hcl
output "couchdb_url" {
  value = "http://${google_compute_instance.obsidian_couchdb_vm.network_interface[0].access_config[0].nat_ip}:5984"
}
```

After Terraform runs, outputs tell you the important information—like what IP address your VM got. That gnarly line is just navigating Terraform's data structure to find the VM's external IP.

#### `provider.tf` - The Connection to GCP

```hcl
provider "google" {
  project = var.project_id
  region  = var.region
}
```

This tells Terraform "we're working with Google Cloud, and here's which project to use." The actual authentication happens via environment variables or `gcloud auth`.

#### `backend.tf` - Where Terraform Stores Its Memory

Terraform keeps track of what it created in a "state file." By default, this is local (`terraform.tfstate`), but that's problematic for CI/CD—GitHub Actions wouldn't have access to it.

The solution: Store state in a GCS bucket. The state file contains sensitive information (like your VM's IP), so keeping it in cloud storage is both practical and secure.

### GitHub Actions: The Automation Engine

#### `.github/workflows/deploy.yml` - The CI/CD Pipeline

This is where the magic of "push to deploy" happens:

```yaml
on:
  push:
    branches: [main]
```

"When someone pushes to main, do these things..."

**The Workload Identity Federation Part** (this is cool):

Traditional approach: Store a GCP service account key in GitHub Secrets. Problem: Long-lived credentials that could be stolen.

WIF approach: GitHub Actions gets a short-lived OIDC token. It presents this to GCP saying "I'm GitHub Actions running in repo X." GCP verifies the token and grants temporary access.

```yaml
- uses: google-github-actions/auth@v2
  with:
    workload_identity_provider: ${{ vars.WIF_PROVIDER }}
    service_account: ${{ vars.WIF_SERVICE_ACCOUNT }}
```

**No keys stored anywhere!** This is a best practice that many developers don't know about.

---

## Lessons and Gotchas

### Lesson 1: The Free Tier is a Trap (Sort Of)

GCP's free tier is real and generous, but it has gotchas:

- **Only specific regions**: us-west1, us-central1, us-east1
- **Only one e2-micro**: If you run two, the second costs money
- **Egress charges**: Free tier includes 1GB/month to internet. Heavy syncing could exceed this.

**Lesson**: Always set up billing alerts. Even "free" tiers can surprise you.

### Lesson 2: Security by Default is Broken

The default `allowed_ips = ["0.0.0.0/0"]` means **anyone on the internet can try to connect**. We did this for initial testing, but it's dangerous to leave.

**Lesson**: Always restrict firewall rules to specific IPs after initial setup. Better yet, use Tailscale and have no open ports at all.

### Lesson 3: Startup Scripts Are "Eventually Consistent"

When Terraform says "VM created successfully," the startup script might still be running. CouchDB won't be ready for 2-3 minutes after deployment.

**Lesson**: Build in waiting/polling logic if you need to programmatically verify the deployment worked.

### Lesson 4: State Files Are Sensitive

The Terraform state file contains everything—including your secrets if you're not careful. That's why:
- We mark `couchdb_password` as `sensitive`
- We store state in GCS (not git)
- The `.gitignore` excludes `.tfvars` files

**Lesson**: Treat Terraform state like a database backup—sensitive and important.

### Lesson 5: The Workload Identity Dance

Setting up WIF is complex, but it's worth it. The manual steps are:

1. Create a "pool" (a container for identity providers)
2. Create a "provider" (tells GCP to trust GitHub's tokens)
3. Create a service account (the identity Terraform will use)
4. Connect them (allow the provider to impersonate the service account)

**Lesson**: Modern cloud authentication is about short-lived tokens and trust relationships, not long-lived keys.

---

## How Good Engineers Think About This

### Principle 1: Separate Concerns

Notice how the files are organized:
- `main.tf` - The resources themselves
- `variables.tf` - The inputs
- `outputs.tf` - The results
- `provider.tf` - The connection configuration

This isn't required (you could put everything in one file), but it makes the code easier to navigate and maintain.

### Principle 2: Make the Implicit Explicit

The README has a checklist of manual steps. Why? Because some things genuinely can't be automated (like creating a billing-enabled GCP project), and pretending otherwise just confuses users.

### Principle 3: Defense in Depth

Security layers:
1. Firewall rules (network level)
2. CouchDB authentication (application level)
3. Sensitive variable marking (infrastructure level)
4. Tailscale option (network isolation)

No single layer is perfect, so we stack them.

### Principle 4: Make Rollback Possible

Terraform tracks state, so you can always see what exists and destroy it if needed:
```bash
terraform destroy  # Deletes everything
```

### Principle 5: Log Everything

The startup script redirects output to `/var/log/couchdb-setup.log`. When something goes wrong (and it will), logs are your friend.

---

## The Tailscale Addition (Why It's Great)

Tailscale deserves special mention because it fundamentally changes the security model:

**Without Tailscale**:
- Your CouchDB is on the public internet
- Protected only by password + firewall rules
- Anyone who guesses the password or exploits a bug can access it

**With Tailscale**:
- CouchDB has NO public exposure
- Only devices on your Tailscale network can even see it
- The VM has a private IP (100.x.x.x) that only you can access

It's like the difference between putting a lock on your front door vs. building your house inside a gated community.

**Installing Tailscale** (from the VM):
```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
# Authenticate via the URL it shows
```

Then update your Obsidian LiveSync to use the Tailscale IP instead of the public IP.

---

## What Could Go Wrong (And How to Fix It)

| Problem | Cause | Fix |
|---------|-------|-----|
| "Connection refused" | Startup script still running | Wait 3 minutes |
| "401 Unauthorized" | Wrong password | Check COUCHDB_PASSWORD secret |
| "Network unreachable" | Wrong firewall rules | Check allowed_ips |
| GitHub Actions fails auth | WIF misconfigured | Re-check provider and SA settings |
| High GCP bill | Exceeded free tier | Check region, check if you have other resources |

---

## What You've Learned

By working through this project, you've touched:

1. **Terraform** - Infrastructure as code, resource dependencies, state management
2. **GCP** - VMs, firewall rules, IAM, Workload Identity Federation
3. **Docker** - Running containers on VMs
4. **GitHub Actions** - CI/CD, OIDC authentication, environment secrets
5. **CouchDB** - A database designed for sync (even if we're just using it as a black box)
6. **Security thinking** - Defense in depth, principle of least privilege, credential management

Not bad for a "simple" sync server!

---

## Next Steps If You Want to Go Deeper

1. **Add HTTPS**: Use Caddy or nginx with Let's Encrypt
2. **Add monitoring**: GCP Cloud Monitoring with uptime checks
3. **Add backups**: Scheduled disk snapshots
4. **Multi-region**: Replicate CouchDB to another region for redundancy
5. **Cost optimization**: Use preemptible VMs (but they can be shut down anytime)

---

*Remember: The best infrastructure is the one you understand. Take time to read the code, experiment, break things, and learn.*
