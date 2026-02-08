# ☁️ Obsidian GCP Vault

[![Terraform](https://img.shields.io/badge/Terraform-7B42BC?style=for-the-badge&logo=terraform&logoColor=white)](https://www.terraform.io/)
[![GCP](https://img.shields.io/badge/Google_Cloud-4285F4?style=for-the-badge&logo=google-cloud&logoColor=white)](https://cloud.google.com/)
[![GitHub Actions](https://img.shields.io/badge/GitHub_Actions-2088FF?style=for-the-badge&logo=github-actions&logoColor=white)](https://github.com/features/actions)
[![License](https://img.shields.io/badge/License-MIT-green.svg?style=for-the-badge)](LICENSE)

---

## 🚀 Introduction

**Obsidian GCP Vault** is a professional-grade, **completely free** infrastructure for your personal knowledge base. By leveraging Google Cloud's always-free tier, it deploys a private CouchDB instance that serves as a high-performance backend for [Obsidian Self-hosted LiveSync](https://github.com/vrtmrz/obsidian-livesync).

### ✨ Why Obsidian GCP Vault?

*   **💰 Zero Cost**: Optimized for the GCP free tier ($0/month).
*   **🔒 Privacy First**: End-to-end encrypted synchronization.
*   **🤖 AI Ready**: Turn your notes into a knowledge base for LLMs like Claude and Copilot.
*   **⚙️ Developer First**: Fully automated deployment via GitHub Actions & Terraform.

---

## 📋 Table of Contents

- [📐 Architecture Overview](#architecture-overview)
- [🌎 Free Tier Regions](#free-tier-regions-important)
- [📋 Prerequisites](#prerequisites)
- [🛠️ Setup Instructions](#setup-instructions)
  - [Step 1: Enable GCP APIs](#manual-step-1-enable-gcp-apis)
  - [Step 2: Terraform State Bucket](#manual-step-2-create-gcs-bucket-for-terraform-state)
  - [Step 3: Workload Identity Federation](#manual-step-3-set-up-workload-identity-federation)
  - [Step 4: Tailscale Integration](#manual-step-4-optional-get-tailscale-auth-key)
  - [Step 5: GitHub Configuration](#manual-step-5-configure-github-repository)
  - [Step 6: CI/CD Deployment](#step-6-deploy-via-cicd)
- [📱 Obsidian Configuration](#step-7-configure-obsidian-livesync-desktop-only---initial-setup)
- [🔐 HTTPS & Mobile Access](#step-75-add-https-for-mobile-access-required-for-mobile)
- [🔄 Syncing Customizations](#step-9-syncing-plugins--customizations-cheat-sheet)
- [🛡️ Security Recommendations](#security-recommendations)
- [🩺 Troubleshooting](#troubleshooting)
- [🧠 Learnings & Internals](#understanding-your-setup)

---

## 📐 Architecture Overview

### Full System Architecture (CouchDB + Git + LLM Integration)

```
┌─────────────────────────────────────────────────────────────────┐
│                       Your Obsidian Vault                       │
│                                                                 │
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
│                      Google Cloud Platform                      │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │                  e2-micro VM (Free Tier)                   │ │
│  │  ┌──────────────────────────────────────────────────────┐  │ │
│  │  │               CouchDB Container :5984                │  │ │
│  │  │          (LiveSync Backend - Device Sync)            │  │ │
│  │  └──────────────────────────────────────────────────────┘  │ │
│  │        Optional: Tailscale (Private Network Access)         │ │
│  └────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
                                 │
                                 │ Git commits (desktop only)
                                 ▼
┌─────────────────────────────────────────────────────────────────┐
│                        GitHub Repository                        │
│               (Markdown files + Version Control)                │
│                                                                 │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐         │
│  │ Notes/   │  │ Daily/   │  │Projects/ │  │Resources/│         │
│  │  note1.md│  │  2025-.. │  │  proj.md │  │  ref.md  │         │
│  └──────────┘  └──────────┘  └──────────┘  └──────────┘         │
└─────────────────────────────────────────────────────────────────┘
                                 │
                                 │ AI Integration
                                 ▼
┌─────────────────────────────────────────────────────────────────┐
│                      LLM Integration Layer                      │
│                                                                 │
│  ┌────────────┐  ┌────────────┐  ┌────────────┐  ┌──────────┐   │
│  │ Claude.ai  │  │   Copilot  │  │   Cursor   │  │ Custom   │   │
│  │ Projects   │  │            │  │            │  │ LLM APIs │   │
│  └────────────┘  └────────────┘  └────────────┘  └──────────┘   │
│                                                                 │
│  "Analyze my notes on..."                                       │
│  "Summarize this week's journal entries"                        │
│  "Find connections between my project notes"                    │
└─────────────────────────────────────────────────────────────────┘
```

### 🧠 Why This Dual-Layer Approach?

| Layer | Purpose | Benefits |
| :--- | :--- | :--- |
| **CouchDB** | Real-time Device Sync | ✅ All devices (mobile included), Encrypted, Automatic. |
| **Git (Optional)** | AI Knowledge Base | ✅ Long-term history, AI-accessible (Claude/Copilot). |

> [!TIP]
> **CouchDB** is for active sync across all devices. **Git** is for your AI knowledge base and version control (Desktop only).

### ⚖️ Cost Expectation

**$0/month** for light personal use within GCP free tier limits:
*   **1 e2-micro VM** instance (must be in specific regions).
*   **30 GB** standard persistent disk.
*   **1 GB** egress to internet per month.
*   **GCS storage** for Terraform state (~pennies).

> [!CAUTION]
> Exceeding free tier limits will incur charges. Monitor your usage in the GCP Console.

---

## 🌎 Free Tier Regions (IMPORTANT!)

GCP's **always-free tier** for e2-micro VMs is **only available** in these **3 US regions**:

| Region | Location | Default in This Setup |
| :--- | :--- | :---: |
| **us-west1** | Oregon | |
| **us-central1** | Iowa | ✅ **DEFAULT** |
| **us-east1** | South Carolina | |

> [!NOTE]
> This setup defaults to `us-central1-a`. You don't need to change anything unless you want a different region for lower latency.

---

## 📋 Prerequisites

Before starting, ensure you have:

*   [ ] A **Google Cloud Platform** account.
*   [ ] A GCP project with **billing enabled** (free tier requires it, but won't charge within limits).
*   [ ] **gcloud CLI** installed and authenticated.
*   [ ] **Terraform 1.5+** installed (or use GitHub Actions only).
*   [ ] A **GitHub** account (for CI/CD).
*   [ ] *(Optional)* **Tailscale** account for private networking.

---

## 🛠️ Setup Instructions

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

### 2️⃣ Create GCS Bucket for Terraform State

Terraform state must be stored remotely for CI/CD to work.

```bash
# Create a globally unique bucket name
export BUCKET_NAME="obsidian-couchdb-tfstate-$(openssl rand -hex 4)"
echo "Your bucket name: $BUCKET_NAME"

# Create the bucket (use a free-tier eligible region)
gsutil mb -p $PROJECT_ID -l us-central1 -b on gs://$BUCKET_NAME

# Enable versioning (allows state recovery if something goes wrong)
gsutil versioning set on gs://$BUCKET_NAME
```

> [!IMPORTANT]
> **After creating the bucket, update `backend.tf`:**
> 1.  Uncomment the `backend "gcs"` block.
> 2.  Replace the `bucket` name with your actual bucket name.

---

### 3️⃣ Set Up Workload Identity Federation

This allows GitHub Actions to authenticate to GCP **without storing any long-lived keys**.

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

Save the output—it looks like:
`projects/123456789/locations/global/workloadIdentityPools/github-actions-pool/providers/github-provider`

---

### 4️⃣ (Optional) Get Tailscale Auth Key

If you want **automated Tailscale installation** (highly recommended for security):

1.  Go to [Tailscale Keys](https://login.tailscale.com/admin/settings/keys).
2.  Click **Generate auth key**.
3.  Settings: ✅ **Reusable**, set expiration as preferred.
4.  Copy the key (starts with `tskey-auth-...`).

---

### 5️⃣ Configure GitHub Repository

#### 5.1 Create the Repository

```bash
# Clone this repo or create a new one
gh repo create obsidian-gce-couchdb --private
```

#### 5.2 Set GitHub Variables

| Variable Name | Value |
| :--- | :--- |
| `GCP_PROJECT_ID` | Your GCP project ID |
| `WIF_PROVIDER` | Full provider name from Step 3.6 |
| `WIF_SERVICE_ACCOUNT` | `terraform-github-actions@YOUR_PROJECT_ID.iam.gserviceaccount.com` |

#### 5.3 Set GitHub Secrets

| Secret Name | Value | Required? |
| :--- | :--- | :---: |
| `COUCHDB_PASSWORD` | A strong password (min 12 characters) | ✅ Required |
| `TAILSCALE_AUTH_KEY` | Tailscale auth key from Step 4 | ⚙️ Optional |

---

### 6️⃣ Deploy via CI/CD

1.  Push to `main` branch:

```bash
git add .
git commit -m "Initial deployment"
git push origin main
```

2.  Watch the GitHub Actions workflow run.
3.  Check the workflow summary for outputs (**VM IP**, **CouchDB URL**).
4.  Wait 2-3 minutes for the startup script to complete.

---

### 7️⃣ Configure Obsidian LiveSync (Desktop)

1.  In Obsidian, install the **Self-hosted LiveSync** plugin.
2.  Configure the plugin:
    *   **Server URL**: `http://YOUR_VM_IP:5984`
    *   **Username**: `admin`
    *   **Password**: Your CouchDB password
    *   **Database**: `obsidian`
    *   **End-to-end encryption**: Enable and set a passphrase.

> [!WARNING]
> **Mobile requires HTTPS** - see Step 7.5.

---

### 7.5️⃣ Add HTTPS for Mobile Access (REQUIRED)

Mobile Obsidian requires HTTPS. Choose one of the following:

<details>
<summary><b>Option 1: Tailscale (Recommended)</b></summary>

*   **Pros**: Private VPN, most secure.
*   **Cons**: Requires Tailscale app on all devices.

Use `http://100.x.x.x:5984` (Tailscale IP) even though it's HTTP, mobile apps usually allow it over local/VPN networks.

</details>

<details>
<summary><b>Option 2: DuckDNS + Caddy (Universal Access)</b></summary>

*   **Pros**: Free HTTPS subdomain, works everywhere.
*   **Cons**: Requires port 443 open to the internet.

</details>

---

### 8️⃣ (Optional) Set Up Git for LLM Integration

If you want to make your notes accessible to **Claude.ai**, **GitHub Copilot**, or other LLMs:

1.  Install the **Obsidian Git** plugin.
2.  Initialize Git in your vault and push to a **private** GitHub repo.
3.  Connect the repo to Claude.ai Projects or Copilot.

---

### 9️⃣ Syncing Plugins & Customizations (Cheat Sheet)

To sync plugins, settings, themes, and other customizations across devices:

#### Prerequisites
*   Unique device name set on EVERY device (**Settings → Self-hosted LiveSync → Device name**).

#### Initial Setup
1.  **Main Device**: Enable `Customization sync`, open dialog, **Select All Shiny**, **Apply All Selected**.
2.  **Secondary Devices**: Open dialog, **Select All Shiny**, **Apply**, then **Restart Obsidian**.

---

## 🛡️ Security Recommendations

### 🔒 Recommended Configuration: Tailscale + HTTPS

This is the most secure and flexible setup:

*   **Port 443 (HTTPS)** open for work access.
*   **Tailscale network** for secure home/mobile access.
*   **Port 5984 closed** to the public internet.

---

## 🩺 Troubleshooting

### Plugins, Themes, or Configs not syncing?
If your notes sync but plugins and themes don't, it's usually because CouchDB's default document size limit is too small.

**Fix**: The `main.tf` now includes optimized settings for `max_document_size` (4GB).
1.  **New users**: No action needed, it's configured by default.
2.  **Existing users**:
    *   Pull latest changes and run `terraform apply`.
    *   Restart the VM from GCP console to re-run the startup script.
    *   *Alternatively*, SSH into the VM and run the plugin's "Setup CouchDB" check or execute the manual `curl` commands found in the updated `main.tf`.

### Check Logs on the VM
```bash
sudo cat /var/log/couchdb-setup.log
sudo docker logs obsidian-couchdb
tailscale status
```

---

## 🏗️ File Structure

```
obsidian-cloud/
├── .github/workflows/
│   └── deploy.yml             # CI/CD pipeline
├── main.tf                    # Infrastructure
├── docs/
│   └── LEARNINGS.md           # Deep dive explanation
└── README.md                  # You are here
```

---

## ✅ Manual Steps Checklist

- [ ] **Step 1**: Enable GCP APIs
- [ ] **Step 2**: Create GCS bucket
- [ ] **Step 3**: Set up WIF
- [ ] **Step 4**: (Optional) Tailscale key
- [ ] **Step 5**: GitHub variables/secrets
- [ ] **Step 6**: Push and deploy
- [ ] **Step 7**: Configure Obsidian (Desktop)
- [ ] **Step 7.5**: Add HTTPS for Mobile
- [ ] **Step 8**: (Optional) Git + LLM integration
- [ ] **Step 11**: (Optional) Customization Sync

---

## 📜 License

MIT License - Use freely for personal projects.
