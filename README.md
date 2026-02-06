# Obsidian LiveSync CouchDB Backend on GCP Free-Tier VM

**Terraform + GitHub Actions CI/CD with Workload Identity Federation**

Deploy a personal CouchDB instance for [Obsidian Self-hosted LiveSync](https://github.com/vrtmrz/obsidian-livesync) on Google Cloud's always-free tier. End-to-end encrypted, real-time vault synchronization across all your devices.

## Cost Expectation

**$0/month** for light personal use within GCP free tier limits:
- 1 e2-micro VM instance (in us-west1, us-central1, or us-east1)
- 30 GB standard persistent disk
- 1 GB egress to internet per month
- GCS storage for Terraform state (~pennies)

> **Note:** Exceeding free tier limits will incur charges. Monitor your usage in GCP Console.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        GitHub Actions                            │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────────────┐  │
│  │ Push to main│───▶│ Terraform   │───▶│ Deploy to GCP       │  │
│  └─────────────┘    │ Plan/Apply  │    │ (Workload Identity) │  │
│                     └─────────────┘    └─────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Google Cloud Platform                         │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │                    e2-micro VM                              │ │
│  │  ┌──────────────────────────────────────────────────────┐  │ │
│  │  │                 Docker Container                      │  │ │
│  │  │  ┌────────────────────────────────────────────────┐  │  │ │
│  │  │  │              CouchDB :5984                      │  │  │ │
│  │  │  │         (Obsidian LiveSync Backend)            │  │  │ │
│  │  │  └────────────────────────────────────────────────┘  │  │ │
│  │  └──────────────────────────────────────────────────────┘  │ │
│  │                                                             │ │
│  │  Optional: Tailscale (private access, no open ports)        │ │
│  └────────────────────────────────────────────────────────────┘ │
│                                                                  │
│  ┌─────────────────┐      ┌─────────────────────────────────┐  │
│  │ Firewall Rules  │      │ GCS Bucket (Terraform State)    │  │
│  │ :5984 (CouchDB) │      │                                 │  │
│  │ :22 (SSH, opt)  │      │                                 │  │
│  └─────────────────┘      └─────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

---

## Why Startup Script Instead of Dockerfile?

You might wonder why we use a startup script rather than a Dockerfile. Here's why:

1. **Standard VM Image**: We use Debian 12 (not Container-Optimized OS), which gives us flexibility to install additional tools like Tailscale.

2. **Single Container**: For a single CouchDB container, Docker Compose or Kubernetes would be overkill. A simple `docker run` command suffices.

3. **Transparency**: The startup script shows exactly what's happening—no hidden layers.

4. **Easy Debugging**: You can SSH in, check `/var/log/couchdb-setup.log`, and see exactly what happened.

**Alternative**: GCP offers Container-Optimized OS (COS) where you declare containers in VM metadata. However, COS has limitations (no package manager, harder to add Tailscale).

---

## Prerequisites

Before starting, ensure you have:

- [ ] A Google Cloud Platform account
- [ ] A GCP project with billing enabled (free tier requires billing account)
- [ ] `gcloud` CLI installed and authenticated
- [ ] Terraform 1.5+ installed (or use GitHub Actions only)
- [ ] A GitHub account (for CI/CD)

---

## Setup Instructions

### MANUAL STEP 1: Enable GCP APIs

These APIs must be enabled before Terraform can create resources.

```bash
# Set your project ID
export PROJECT_ID="your-project-id"

# Enable required APIs
gcloud services enable compute.googleapis.com --project=$PROJECT_ID
gcloud services enable iam.googleapis.com --project=$PROJECT_ID
gcloud services enable cloudresourcemanager.googleapis.com --project=$PROJECT_ID
gcloud services enable iamcredentials.googleapis.com --project=$PROJECT_ID
gcloud services enable sts.googleapis.com --project=$PROJECT_ID
```

---

### MANUAL STEP 2: Create GCS Bucket for Terraform State

Terraform state must be stored remotely for CI/CD to work.

```bash
# Create a globally unique bucket name
export BUCKET_NAME="obsidian-couchdb-tfstate-$(openssl rand -hex 4)"
echo "Your bucket name: $BUCKET_NAME"

# Create the bucket (use a free-tier eligible region)
gsutil mb -p $PROJECT_ID -l us-central1 -b on gs://$BUCKET_NAME

# Enable versioning (allows state recovery if something goes wrong)
gsutil versioning set on gs://$BUCKET_NAME

# Save this bucket name - you'll need it later!
echo "IMPORTANT: Save this bucket name: $BUCKET_NAME"
```
obsidian-couchdb-tfstate-4235caa2

After creating the bucket, update `backend.tf`:
1. Uncomment the `backend "gcs"` block
2. Replace `YOUR_UNIQUE_SUFFIX` with your actual bucket name

---

### MANUAL STEP 3: Set Up Workload Identity Federation

This is the most complex manual step. Workload Identity Federation allows GitHub Actions to authenticate to GCP **without storing any long-lived keys**.

#### 3.1 Create a Workload Identity Pool

```bash
gcloud iam workload-identity-pools create "github-actions-pool" \
  --project=$PROJECT_ID \
  --location="global" \
  --display-name="GitHub Actions Pool"
```

#### 3.2 Create the OIDC Provider

Replace `YOUR_GITHUB_USERNAME` with your actual GitHub username:

```bash
gcloud iam workload-identity-pools providers create-oidc "github-provider" \
  --project=$PROJECT_ID \
  --location="global" \
  --workload-identity-pool="github-actions-pool" \
  --display-name="GitHub Provider" \
  --attribute-mapping="google.subject=assertion.sub,attribute.actor=assertion.actor,attribute.repository=assertion.repository,attribute.repository_owner=assertion.repository_owner" \
  --attribute-condition="assertion.repository_owner == 'YOUR_GITHUB_USERNAME'" \
  --issuer-uri="https://token.actions.githubusercontent.com"
```

#### 3.3 Create a Service Account for Terraform

```bash
gcloud iam service-accounts create terraform-github-actions \
  --project=$PROJECT_ID \
  --display-name="Terraform GitHub Actions"
```

#### 3.4 Grant Required Permissions

```bash
# Compute Admin - to manage VMs and firewall rules
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:terraform-github-actions@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/compute.admin"

# Storage Admin - to manage Terraform state in GCS
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:terraform-github-actions@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/storage.admin"
```

#### 3.5 Allow GitHub to Impersonate the Service Account

Replace `YOUR_GITHUB_USERNAME` and `YOUR_REPO_NAME`:

```bash
# Get your project number
export PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format="value(projectNumber)")

# Allow GitHub Actions to use this service account
gcloud iam service-accounts add-iam-policy-binding \
  terraform-github-actions@$PROJECT_ID.iam.gserviceaccount.com \
  --project=$PROJECT_ID \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/github-actions-pool/attribute.repository/YOUR_GITHUB_USERNAME/YOUR_REPO_NAME"
```

#### 3.6 Get the Provider Resource Name

```bash
gcloud iam workload-identity-pools providers describe github-provider \
  --project=$PROJECT_ID \
  --location="global" \
  --workload-identity-pool="github-actions-pool" \
  --format="value(name)"
```

Save this output—it looks like:
```
projects/123456789/locations/global/workloadIdentityPools/github-actions-pool/providers/github-provider
```

**Official Documentation**: [Workload Identity Federation for GitHub Actions](https://cloud.google.com/iam/docs/workload-identity-federation-with-deployment-pipelines)

---

### MANUAL STEP 4: Configure GitHub Repository

#### 4.1 Create the Repository

```bash
# Clone this repo or create a new one
gh repo create obsidian-gce-couchdb --private
```

#### 4.2 Set GitHub Variables (Settings → Secrets and variables → Actions → Variables)

| Variable Name | Value |
|--------------|-------|
| `GCP_PROJECT_ID` | Your GCP project ID |
| `WIF_PROVIDER` | Full provider name from Step 3.6 |
| `WIF_SERVICE_ACCOUNT` | `terraform-github-actions@YOUR_PROJECT_ID.iam.gserviceaccount.com` |

#### 4.3 Set GitHub Secrets (Settings → Secrets and variables → Actions → Secrets)

| Secret Name | Value |
|------------|-------|
| `COUCHDB_PASSWORD` | A strong password (min 12 characters) |

---

### STEP 5: Deploy via CI/CD

1. Copy `terraform.tfvars.example` to `terraform.tfvars` (for local testing only)
2. Push to `main` branch:

```bash
git add .
git commit -m "Initial deployment"
git push origin main
```

3. Watch the GitHub Actions workflow run
4. Check the workflow summary for outputs (VM IP, CouchDB URL)

---

### STEP 6: Configure Obsidian LiveSync

1. Wait 2-3 minutes for the VM startup script to complete
2. Get the CouchDB URL from Terraform outputs or GitHub Actions summary
3. In Obsidian, install the "Self-hosted LiveSync" plugin
4. Configure the plugin:
   - **Server URL**: `http://YOUR_VM_IP:5984`
   - **Username**: `admin` (or your configured username)
   - **Password**: Your CouchDB password
   - **Database**: `obsidian` (or any name you prefer)

---

## Security Recommendations

### CRITICAL: Restrict Firewall After Initial Setup

The default `allowed_ips = ["0.0.0.0/0"]` allows **anyone** to access your CouchDB!

1. Find your IP: `curl ifconfig.me`
2. Update `terraform.tfvars`:
   ```hcl
   allowed_ips = ["YOUR.IP.ADDRESS/32"]
   ```
3. Push the change to trigger a new deployment

### STRONGLY RECOMMENDED: Install Tailscale

[Tailscale](https://tailscale.com/) creates a private mesh VPN, allowing you to access your CouchDB without any open firewall ports.

**SSH into your VM and install Tailscale:**

```bash
# SSH into the VM
gcloud compute ssh obsidian-couchdb-vm --zone=us-central1-a --project=YOUR_PROJECT_ID

# Install Tailscale (one-liner)
curl -fsSL https://tailscale.com/install.sh | sh

# Start Tailscale
sudo tailscale up

# Follow the authentication URL
```

**After Tailscale is connected:**

1. Remove the public firewall rule by setting `allowed_ips = []`
2. Use your VM's Tailscale IP (100.x.x.x) in Obsidian LiveSync settings
3. Your CouchDB is now **only accessible over your private Tailscale network**

### Other Security Options

| Option | Pros | Cons |
|--------|------|------|
| **Tailscale** | Zero-config, free for personal, no open ports | Requires Tailscale on all devices |
| **Cloudflare Tunnel** | Free, adds HTTPS, DDoS protection | More complex setup |
| **Caddy + Let's Encrypt** | Free HTTPS, standard approach | Needs domain, more config |
| **IP Allowlist** | Simple | IP may change, manual updates |

---

## Troubleshooting

### Check Startup Script Logs

```bash
gcloud compute ssh obsidian-couchdb-vm --zone=us-central1-a --project=YOUR_PROJECT_ID

# View startup script logs
sudo cat /var/log/couchdb-setup.log

# Check Docker container status
sudo docker ps
sudo docker logs obsidian-couchdb
```

### Test CouchDB Locally

```bash
# From inside the VM
curl -u admin:YOUR_PASSWORD http://localhost:5984/

# Expected response:
# {"couchdb":"Welcome","version":"3.x.x",...}
```

### Common Issues

| Issue | Solution |
|-------|----------|
| Can't connect to CouchDB | Wait 3 min for startup; check firewall rules |
| 401 Unauthorized | Check username/password in Obsidian settings |
| GitHub Actions auth fails | Verify WIF_PROVIDER and WIF_SERVICE_ACCOUNT values |
| Terraform state error | Ensure GCS bucket exists and backend.tf is configured |

---

## Free Tier Reminders

To stay within GCP's always-free tier:

| Resource | Free Tier Limit | This Setup |
|----------|----------------|------------|
| VM | 1 e2-micro in us-west1/us-central1/us-east1 | 1 e2-micro in us-central1 |
| Disk | 30 GB pd-standard | 30 GB pd-standard |
| Egress | 1 GB/month to internet | Varies by sync usage |
| GCS | 5 GB storage | ~KB for state file |

**Tips:**
- Don't run other e2-micro VMs in free-tier regions
- Monitor egress if syncing large vaults frequently
- Set up billing alerts in GCP Console

---

## Optional Extensions

### Enable VM Snapshots

Add to `main.tf`:

```hcl
resource "google_compute_resource_policy" "daily_backup" {
  name   = "couchdb-daily-backup"
  region = var.region

  snapshot_schedule_policy {
    schedule {
      daily_schedule {
        days_in_cycle = 1
        start_time    = "04:00"
      }
    }
    retention_policy {
      max_retention_days    = 7
      on_source_disk_delete = "KEEP_AUTO_SNAPSHOTS"
    }
  }
}
```

### Add Monitoring Alerts

```bash
# Create an uptime check (GCP Console or Terraform)
# Alert if CouchDB doesn't respond for 5 minutes
```

### Tailscale in Startup Script (Automated)

Add to the startup script in `main.tf` (requires Tailscale auth key):

```bash
# Install Tailscale
curl -fsSL https://tailscale.com/install.sh | sh

# Start with auth key (set TAILSCALE_AUTHKEY in Terraform variables)
tailscale up --authkey=${var.tailscale_auth_key}
```

---

## File Structure

```
obsidian-cloud/
├── .github/
│   └── workflows/
│       └── deploy.yml      # CI/CD pipeline with Workload Identity
├── main.tf                 # VM, firewall, startup script
├── variables.tf            # Input variables
├── outputs.tf              # Output values (IP, URLs)
├── provider.tf             # Terraform & GCP provider config
├── backend.tf              # GCS state backend (configure manually)
├── terraform.tfvars.example # Example variable values
├── .gitignore              # Excludes secrets and state files
└── README.md               # This file
```

---

## Manual Steps Checklist

Use this checklist to track your progress:

- [ ] **Step 1**: Enable GCP APIs
- [ ] **Step 2**: Create GCS bucket for Terraform state
- [ ] **Step 3**: Set up Workload Identity Federation
  - [ ] Create Workload Identity Pool
  - [ ] Create OIDC Provider
  - [ ] Create Service Account
  - [ ] Grant IAM roles
  - [ ] Allow GitHub to impersonate SA
- [ ] **Step 4**: Configure GitHub repository
  - [ ] Set `GCP_PROJECT_ID` variable
  - [ ] Set `WIF_PROVIDER` variable
  - [ ] Set `WIF_SERVICE_ACCOUNT` variable
  - [ ] Set `COUCHDB_PASSWORD` secret
- [ ] **Step 5**: Update `backend.tf` with bucket name
- [ ] **Step 6**: Push to main and deploy
- [ ] **Step 7**: Configure Obsidian LiveSync
- [ ] **Step 8**: Restrict firewall / Install Tailscale

---

## Resources

- [Obsidian Self-hosted LiveSync](https://github.com/vrtmrz/obsidian-livesync)
- [CouchDB Documentation](https://docs.couchdb.org/)
- [GCP Free Tier](https://cloud.google.com/free)
- [Workload Identity Federation](https://cloud.google.com/iam/docs/workload-identity-federation)
- [Tailscale](https://tailscale.com/)

---

## License

MIT License - Use freely for personal projects.
