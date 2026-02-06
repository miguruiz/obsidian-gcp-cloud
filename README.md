# Obsidian LiveSync CouchDB Backend on GCP Free-Tier VM

**Terraform + GitHub Actions CI/CD with Workload Identity Federation**

Deploy a personal CouchDB instance for [Obsidian Self-hosted LiveSync](https://github.com/vrtmrz/obsidian-livesync) on Google Cloud's always-free tier. End-to-end encrypted, real-time vault synchronization across all your devices, with optional Git integration for LLM access (Claude.ai, Copilot, etc.).

## Cost Expectation

**$0/month** for light personal use within GCP free tier limits:
- 1 e2-micro VM instance (**must be** in us-west1, us-central1, or us-east1)
- 30 GB standard persistent disk
- 1 GB egress to internet per month
- GCS storage for Terraform state (~pennies)

> **Note:** Exceeding free tier limits will incur charges. Monitor your usage in GCP Console.

---

## Architecture Overview

### Full System Architecture (CouchDB + Git + LLM Integration)

```
┌─────────────────────────────────────────────────────────────────┐
│                     Your Obsidian Vault                          │
│                                                                  │
│  Mobile (iOS/Android)              Desktop (Mac/Win/Linux)      │
│  ┌──────────────┐                  ┌──────────────┐             │
│  │  Obsidian    │                  │  Obsidian    │             │
│  │  LiveSync ✓  │                  │  LiveSync ✓  │             │
│  │  Git ✗       │                  │  Git Plugin✓ │             │
│  └──────┬───────┘                  └──────┬───────┘             │
│         │                                 │                     │
│         │ Real-time                       │ Real-time           │
│         ├─────────────────────────────────┤                     │
│         │                                 │                     │
└─────────┼─────────────────────────────────┼─────────────────────┘
          │                                 │
          ▼                                 ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Google Cloud Platform                         │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │                    e2-micro VM (Free Tier)                  │ │
│  │  ┌──────────────────────────────────────────────────────┐  │ │
│  │  │              CouchDB Container :5984                  │  │ │
│  │  │         (LiveSync Backend - Device Sync)             │  │ │
│  │  └──────────────────────────────────────────────────────┘  │ │
│  │  Optional: Tailscale (Private Network Access)              │ │
│  └────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
                                 │
                                 │ Git commits (desktop only)
                                 ▼
┌─────────────────────────────────────────────────────────────────┐
│                         GitHub Repository                        │
│              (Markdown files + Version Control)                 │
│                                                                  │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐       │
│  │ Notes/   │  │ Daily/   │  │Projects/ │  │Resources/│       │
│  │  note1.md│  │  2025-.. │  │  proj.md │  │  ref.md  │       │
│  └──────────┘  └──────────┘  └──────────┘  └──────────┘       │
└─────────────────────────────────────────────────────────────────┘
                                 │
                                 │ AI Integration
                                 ▼
┌─────────────────────────────────────────────────────────────────┐
│                        LLM Integration Layer                     │
│                                                                  │
│  ┌────────────┐  ┌────────────┐  ┌────────────┐  ┌──────────┐  │
│  │ Claude.ai  │  │   Copilot  │  │   Cursor   │  │ Custom   │  │
│  │ Projects   │  │            │  │            │  │ LLM APIs │  │
│  └────────────┘  └────────────┘  └────────────┘  └──────────┘  │
│                                                                  │
│  "Analyze my notes on..."                                       │
│  "Summarize this week's journal entries"                        │
│  "Find connections between my project notes"                    │
└─────────────────────────────────────────────────────────────────┘
```

### Why This Dual-Layer Approach?

**Layer 1: CouchDB (Real-time Device Sync)**
- ✅ Syncs across **all devices** including mobile
- ✅ Real-time, automatic, zero-touch
- ✅ End-to-end encrypted
- ✅ Designed for multi-master replication
- ✅ Handles binary files (images, PDFs)

**Layer 2: Git (AI Integration + Version Control)** - OPTIONAL
- ✅ Makes your notes **AI-accessible** (Claude.ai, Copilot, etc.)
- ✅ Long-term version history
- ✅ Browse notes on GitHub web interface
- ✅ Standard format for portability
- ⚠️ Desktop only (Git plugin doesn't work on mobile)

**They serve different purposes:**
- **CouchDB** = Active sync for daily use across all devices
- **Git** = AI knowledge base + backup (optional, but highly recommended for LLM integration)

---

## Free Tier Regions (IMPORTANT!)

GCP's **always-free tier** for e2-micro VMs is **only available** in these **3 US regions**:

| Region | Location | Default in This Setup |
|--------|----------|----------------------|
| **us-west1** | Oregon | |
| **us-central1** | Iowa | ✅ **DEFAULT** |
| **us-east1** | South Carolina | |

**This setup defaults to `us-central1-a`** which is already free-tier compliant. You don't need to change anything unless you want a different region for lower latency.

---

## Prerequisites

Before starting, ensure you have:

- [ ] A Google Cloud Platform account
- [ ] A GCP project with billing enabled (free tier requires a billing account, but won't charge within limits)
- [ ] `gcloud` CLI installed and authenticated
- [ ] Terraform 1.5+ installed (or use GitHub Actions only)
- [ ] A GitHub account (for CI/CD)
- [ ] (Optional) Tailscale account for private networking

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

After creating the bucket, update `backend.tf`:
1. Uncomment the `backend "gcs"` block (if commented)
2. Replace the bucket name with your actual bucket name

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

### MANUAL STEP 4: (Optional) Get Tailscale Auth Key

If you want **automated Tailscale installation** (highly recommended for security):

1. Go to https://login.tailscale.com/admin/settings/keys
2. Click "Generate auth key"
3. Settings:
   - ✅ **Reusable** (so VM can reconnect after restarts)
   - Set expiration or make it non-expiring for personal use
4. Copy the key (starts with `tskey-auth-...`)

You'll add this as a GitHub secret in the next step.

---

### MANUAL STEP 5: Configure GitHub Repository

#### 5.1 Create the Repository

```bash
# Clone this repo or create a new one
gh repo create obsidian-gce-couchdb --private
```

#### 5.2 Set GitHub Variables (Settings → Secrets and variables → Actions → Variables)

| Variable Name | Value |
|--------------|-------|
| `GCP_PROJECT_ID` | Your GCP project ID |
| `WIF_PROVIDER` | Full provider name from Step 3.6 |
| `WIF_SERVICE_ACCOUNT` | `terraform-github-actions@YOUR_PROJECT_ID.iam.gserviceaccount.com` |

#### 5.3 Set GitHub Secrets (Settings → Secrets and variables → Actions → Secrets)

| Secret Name | Value | Required? |
|------------|-------|-----------|
| `COUCHDB_PASSWORD` | A strong password (min 12 characters) | ✅ Required |
| `TAILSCALE_AUTH_KEY` | Tailscale auth key from Step 4 | ⚙️ Optional (but recommended) |

---

### STEP 6: Deploy via CI/CD

1. Copy `terraform.tfvars.example` to `terraform.tfvars` (for local testing only, don't commit it)
2. Push to `main` branch:

```bash
git add .
git commit -m "Initial deployment"
git push origin main
```

3. Watch the GitHub Actions workflow run
4. Check the workflow summary for outputs (VM IP, CouchDB URL)
5. Wait 2-3 minutes for the startup script to complete

---

### STEP 7: Configure Obsidian LiveSync

1. Get the CouchDB URL from Terraform outputs or GitHub Actions summary
2. In Obsidian (desktop and mobile), install the "Self-hosted LiveSync" plugin
3. Configure the plugin:
   - **Server URL**: `http://YOUR_VM_IP:5984` (or `http://100.x.x.x:5984` if using Tailscale)
   - **Username**: `admin` (or your configured username)
   - **Password**: Your CouchDB password
   - **Database**: `obsidian` (or any name you prefer)
   - **End-to-end encryption**: Enable and set a passphrase

---

### STEP 8 (Optional): Set Up Git for LLM Integration

If you want to make your notes accessible to Claude.ai, GitHub Copilot, or other LLMs:

#### 8.1 Install Obsidian Git Plugin (Desktop Only)

1. Obsidian → Settings → Community plugins → Browse
2. Search "Obsidian Git"
3. Install and enable

#### 8.2 Initialize Git in Your Vault

```bash
cd /path/to/your/ObsidianVault

# Initialize git
git init

# Create .gitignore
cat > .gitignore << 'EOF'
# Obsidian workspace and cache
.obsidian/workspace*.json
.obsidian/cache/

# Keep core config
!.obsidian/app.json
!.obsidian/appearance.json
!.obsidian/community-plugins.json

# Exclude LiveSync database (binary, not useful for AI)
.obsidian/plugins/obsidian-livesync/

# OS files
.DS_Store
Thumbs.db
EOF

# Initial commit
git add .
git commit -m "Initial vault backup"
```

#### 8.3 Create GitHub Repo for Your Vault

```bash
# Create a PRIVATE repo for your notes
gh repo create my-obsidian-vault --private

# Push your vault
git remote add origin https://github.com/yourusername/my-obsidian-vault.git
git push -u origin main
```

#### 8.4 Configure Obsidian Git Plugin

- Settings → Obsidian Git:
  - **Auto backup interval**: 60 minutes (or as preferred)
  - **Auto pull on startup**: Enabled
  - **Auto push**: Enabled
  - **Commit message**: `vault backup: {{date}}`

#### 8.5 Connect to Claude.ai (or Other LLMs)

**For Claude.ai:**
1. Go to https://claude.ai
2. Create a new Project
3. Add your GitHub repository as knowledge
4. Now you can ask Claude to analyze, search, and summarize your notes!

**For GitHub Copilot/Cursor:**
- These will automatically have context from your vault repo when you have it open

---

## Security Recommendations

### CRITICAL: Restrict Firewall After Initial Setup

The default `allowed_ips = ["0.0.0.0/0"]` allows **anyone** to access your CouchDB!

**Option A: Restrict to Your IP**
1. Find your IP: `curl ifconfig.me`
2. Update `terraform.tfvars`:
   ```hcl
   allowed_ips = ["YOUR.IP.ADDRESS/32"]
   ```
3. Push the change to trigger a new deployment

**Option B: Use Tailscale (Recommended)**

If you added `TAILSCALE_AUTH_KEY` as a GitHub secret, Tailscale is already installed!

1. **Get your VM's Tailscale IP**:
   ```bash
   gcloud compute ssh obsidian-couchdb-vm --zone=us-central1-a --project=YOUR_PROJECT_ID
   tailscale ip -4  # Shows your 100.x.x.x IP
   ```

2. **Update Obsidian LiveSync** to use the Tailscale IP:
   - Server URL: `http://100.x.x.x:5984`

3. **Close the public firewall**:
   ```hcl
   # In terraform.tfvars
   allowed_ips = []
   ```
   Push to redeploy.

4. **Install Tailscale on your devices**:
   - Desktop: https://tailscale.com/download
   - Mobile: Install from App Store / Play Store

Now your CouchDB is **only accessible over your private Tailscale network**!

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

# Check Tailscale status (if enabled)
tailscale status
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
| Can't connect to CouchDB | Wait 3 min for startup; check firewall rules; verify IP |
| 401 Unauthorized | Check username/password in Obsidian settings |
| GitHub Actions auth fails | Verify WIF_PROVIDER and WIF_SERVICE_ACCOUNT values |
| Terraform state error | Ensure GCS bucket exists and backend.tf is configured |
| Tailscale not working | Check TAILSCALE_AUTH_KEY is set; view logs on VM |
| Git not syncing on mobile | Normal - Git plugin is desktop-only. Use LiveSync for mobile. |

---

## Understanding Your Setup

### What Syncs Where?

```
Mobile Obsidian
    ↓ LiveSync only (Git plugin doesn't work on mobile)
    ↓
CouchDB (GCP VM)
    ↑
    ↓ LiveSync
    ↓
Desktop Obsidian
    ↓ Git plugin (commits to GitHub)
    ↓
GitHub Repo
    ↓ AI can read
    ↓
Claude.ai / Copilot / etc.
```

### Why Not Just Use Git for Everything?

- **Git doesn't work well on mobile** (sandboxing limitations)
- **Git isn't designed for real-time sync** (requires manual commits/pushes)
- **CouchDB is purpose-built** for multi-device, multi-master replication
- **Git adds LLM integration** that CouchDB doesn't provide

---

## Free Tier Reminders

To stay within GCP's always-free tier:

| Resource | Free Tier Limit | This Setup |
|----------|----------------|------------|
| VM | 1 e2-micro in **us-west1/us-central1/us-east1 ONLY** | 1 e2-micro in us-central1 ✅ |
| Disk | 30 GB pd-standard | 30 GB pd-standard ✅ |
| Egress | 1 GB/month to internet (from North America) | Varies by sync usage ⚠️ |
| GCS | 5 GB storage | ~KB for state file ✅ |

**Tips:**
- Don't run other e2-micro VMs in free-tier regions (limit is 1 total, not 1 per region)
- Monitor egress if syncing large vaults frequently
- Set up billing alerts in GCP Console
- Only us-west1, us-central1, and us-east1 qualify for free tier

**Set up a billing alert:**
```bash
gcloud billing budgets create \
  --billing-account=YOUR_BILLING_ACCOUNT_ID \
  --display-name="Free Tier Alert" \
  --budget-amount=1USD \
  --threshold-rule=percent=50
```

---

## LLM Integration Ideas

Once your vault is in GitHub, you can:

### With Claude.ai
- "Summarize all my notes about project X"
- "Find connections between my notes on topic A and topic B"
- "What were my main insights from this week's journal entries?"
- "Help me organize my notes by creating an index"

### With Copilot/Cursor
- Use your notes as context while coding
- Reference your documentation while writing
- Auto-complete based on your personal knowledge base

### Custom Automations (GitHub Actions)
- Daily summary emails
- Automated tagging
- Cross-reference finder
- Orphaned note detector

---

## File Structure

```
obsidian-cloud/                    # This infrastructure repo
├── .github/
│   └── workflows/
│       └── deploy.yml             # CI/CD pipeline
├── main.tf                        # VM, firewall, startup script
├── variables.tf                   # Input variables
├── outputs.tf                     # Output values
├── provider.tf                    # Terraform config
├── backend.tf                     # GCS state backend
├── terraform.tfvars.example       # Example values
├── .gitignore                     # Excludes secrets
├── README.md                      # This file
└── FOR_miguruiz.md                # Deep dive explanation

your-obsidian-vault/               # Separate repo for your notes
├── .obsidian/
│   ├── app.json
│   └── community-plugins.json
├── Daily/
├── Projects/
├── Resources/
├── .gitignore
└── README.md                      # Vault structure for AI
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
- [ ] **Step 4**: (Optional) Get Tailscale auth key
- [ ] **Step 5**: Configure GitHub repository
  - [ ] Set `GCP_PROJECT_ID` variable
  - [ ] Set `WIF_PROVIDER` variable
  - [ ] Set `WIF_SERVICE_ACCOUNT` variable
  - [ ] Set `COUCHDB_PASSWORD` secret
  - [ ] Set `TAILSCALE_AUTH_KEY` secret (optional)
- [ ] **Step 6**: Push to main and deploy
- [ ] **Step 7**: Configure Obsidian LiveSync on all devices
- [ ] **Step 8**: (Optional) Set up Git + LLM integration
  - [ ] Install Obsidian Git plugin (desktop)
  - [ ] Initialize git in vault
  - [ ] Create GitHub repo for vault
  - [ ] Configure auto-commit/push
  - [ ] Add vault repo to Claude.ai Projects
- [ ] **Step 9**: Restrict firewall or enable Tailscale

---

## Resources

- [Obsidian Self-hosted LiveSync](https://github.com/vrtmrz/obsidian-livesync)
- [Obsidian Git Plugin](https://github.com/denolehov/obsidian-git)
- [CouchDB Documentation](https://docs.couchdb.org/)
- [GCP Free Tier](https://cloud.google.com/free)
- [Workload Identity Federation](https://cloud.google.com/iam/docs/workload-identity-federation)
- [Tailscale](https://tailscale.com/)
- [Claude.ai Projects](https://claude.ai)

---

## License

MIT License - Use freely for personal projects.
