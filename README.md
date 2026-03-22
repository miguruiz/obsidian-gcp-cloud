# ☁️ Obsidian Cloud VM

[![Terraform](https://img.shields.io/badge/Terraform-7B42BC?style=for-the-badge&logo=terraform&logoColor=white)](https://www.terraform.io/)
[![GCP](https://img.shields.io/badge/Google_Cloud-4285F4?style=for-the-badge&logo=google-cloud&logoColor=white)](https://cloud.google.com/)
[![GitHub Actions](https://img.shields.io/badge/GitHub_Actions-2088FF?style=for-the-badge&logo=github-actions&logoColor=white)](https://github.com/features/actions)
[![License](https://img.shields.io/badge/License-MIT-green.svg?style=for-the-badge)](LICENSE)

**Terraform + GitHub Actions CI/CD on a GCP free-tier e2-micro VM.**

Modular personal infrastructure for syncing an Obsidian vault to a server, exposing it as an MCP tool for Claude.ai, and running scheduled LLM automations. Each service is independently toggled via feature flags — no VM recreation needed to add or update services.

> [!NOTE]
> **Cost: ~$0/month** within GCP free tier (e2-micro in us-west1, us-central1, or us-east1 only).

---

## ✅ TODO

- [ ] Follow manual steps (see [Manual Steps After Deployment](#️-manual-steps-after-deployment))
- [ ] Test the MCP from Claude

---

## 📋 Table of Contents

- [🧩 Services](#-services)
- [📐 Architecture](#-architecture)
- [🛠️ Setup](#️-setup)
  - [1. Enable GCP APIs](#1-enable-gcp-apis)
  - [2. Terraform State Bucket](#2-create-gcs-bucket-for-terraform-state)
  - [3. Workload Identity Federation](#3-set-up-workload-identity-federation)
  - [4. GitHub Variables & Secrets](#4-configure-github-repository)
  - [5. Deploy](#5-deploy)
- [🖐️ Manual Steps After Deployment](#️-manual-steps-after-deployment)
- [📄 Prompt File Format](#-prompt-file-format)
- [✅ Verification](#-verification)
- [🏗️ File Structure](#️-file-structure)
- [🩺 Troubleshooting](#-troubleshooting)
- [📚 Resources](#-resources)

---

## 🧩 Services

Each service lives in its own folder under `services/` and is independently controlled by a GitHub Actions variable (feature flag). All default to `false` — enable only what you need.

| Service | Flag | What it does | Dependencies |
|---------|------|--------------|--------------|
| **obsidian-sync** | `ENABLE_OBSIDIAN_SYNC` | Continuously pulls vault from Obsidian Sync to `/opt/obsidian-vault/` on the VM | Obsidian Sync subscription; manual `ob login` after deploy |
| **MCPVault** | `ENABLE_MCPVAULT` | Runs an MCP server over your vault so Claude.ai can read and search your notes | `ENABLE_OBSIDIAN_SYNC` + `ENABLE_HTTPS` for Claude.ai iOS |
| **Claude CLI** | `ENABLE_CLAUDE_CLI` | Installs `claude` on the VM for cron-based vault automation | Manual `claude login` after deploy |
| **obsidian-runner** | `ENABLE_RUNNER` | Python daemon: reads `schedules.yaml` from vault, fires LLM prompts on cron, writes results back as markdown | `ENABLE_OBSIDIAN_SYNC`; manual schedule file setup |
| **Caddy (HTTPS)** | `ENABLE_HTTPS` | Public HTTPS via DuckDNS + Caddy + Let's Encrypt. Required for Claude.ai iOS | `DUCKDNS_SUBDOMAIN` + `DUCKDNS_TOKEN` |
| **Tailscale** | `TAILSCALE_AUTH_KEY` (secret) | Private VPN for SSH access without opening port 22 | Tailscale account |
| **CouchDB** | `ENABLE_COUCHDB` | Legacy: self-hosted CouchDB for Obsidian LiveSync plugin (disabled — using Obsidian Sync) | `COUCHDB_PASSWORD` secret |

> [!TIP]
> **Recommended setup:** `ENABLE_OBSIDIAN_SYNC` + `ENABLE_MCPVAULT` + `ENABLE_HTTPS` + `ENABLE_RUNNER` + `TAILSCALE_AUTH_KEY`. This gives you Claude.ai vault access, scheduled automation, and private SSH.

---

## 📐 Architecture

```
Obsidian Sync (cloud)
       │ continuous pull (obsidian-sync systemd service)
       ▼
/opt/obsidian-vault/              ← vault files on disk
       │
       ├── MCPVault (stdio → supergateway → :3000 SSE)
       │       └── Caddy (:443, HTTPS + basicauth, Let's Encrypt)
       │               └── Claude.ai iOS / Web
       │                   (Anthropic's servers connect to your public URL)
       │
       └── obsidian-runner (Python daemon, wakes every 30s)
               reads  00-Inbox/_other/schedules.yaml   ← edit from any device
               writes 00-Inbox/_other/schedules-log.md ← visible in Obsidian
               runs prompt .md files → writes LLM output back to vault
```

**CI/CD layers:**

| Layer | What | How | Trigger |
|-------|------|-----|---------|
| **Infrastructure** | VM, firewall, GCP resources | Terraform | `infra/**` changes |
| **Services** | CLIs, Python daemons, systemd units | `services/deploy.sh` via IAP SSH | `services/**` changes |
| **Environment** | Tailscale auth, `claude login`, `ob login` | Manual (one-time) | VM recreation only |

---

## 🛠️ Setup

### 1. Enable GCP APIs

```bash
export PROJECT_ID="your-project-id"
gcloud services enable compute.googleapis.com iam.googleapis.com \
  cloudresourcemanager.googleapis.com iamcredentials.googleapis.com \
  sts.googleapis.com --project=$PROJECT_ID
```

### 2. Create GCS Bucket for Terraform State

```bash
export BUCKET_NAME="obsidian-tfstate-$(openssl rand -hex 4)"
gsutil mb -p $PROJECT_ID -l us-central1 -b on gs://$BUCKET_NAME
gsutil versioning set on gs://$BUCKET_NAME
```

> [!IMPORTANT]
> Update `infra/backend.tf` with your bucket name after creating it.

### 3. Set Up Workload Identity Federation

Allows GitHub Actions to authenticate to GCP **without storing any long-lived keys**.

```bash
# Pool + provider
gcloud iam workload-identity-pools create "github-actions-pool" \
  --project=$PROJECT_ID --location="global"

gcloud iam workload-identity-pools providers create-oidc "github-provider" \
  --project=$PROJECT_ID --location="global" \
  --workload-identity-pool="github-actions-pool" \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.repository_owner=assertion.repository_owner" \
  --attribute-condition="assertion.repository_owner == 'YOUR_GITHUB_USERNAME'" \
  --issuer-uri="https://token.actions.githubusercontent.com"

# Service account
gcloud iam service-accounts create terraform-github-actions \
  --project=$PROJECT_ID --display-name="Terraform GitHub Actions"

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:terraform-github-actions@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/compute.admin"

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:terraform-github-actions@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/storage.admin"

# IAP tunnel access (required for CI/CD to SSH into the VM)
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:terraform-github-actions@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/iap.tunnelResourceAccessor"

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:terraform-github-actions@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/compute.instanceAdmin.v1"

# Allow GitHub to impersonate the SA
export PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format="value(projectNumber)")

gcloud iam service-accounts add-iam-policy-binding \
  terraform-github-actions@$PROJECT_ID.iam.gserviceaccount.com \
  --project=$PROJECT_ID \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/github-actions-pool/attribute.repository/YOUR_GITHUB_USERNAME/YOUR_REPO_NAME"

# Save this output — needed for WIF_PROVIDER GitHub variable
gcloud iam workload-identity-pools providers describe github-provider \
  --project=$PROJECT_ID --location="global" \
  --workload-identity-pool="github-actions-pool" \
  --format="value(name)"
```

### 4. Configure GitHub Repository

**Variables** (Settings → Secrets and variables → Actions → Variables):

| Name | Value |
|------|-------|
| `GCP_PROJECT_ID` | Your GCP project ID |
| `GCP_ZONE` | `us-central1-a` (or your zone) |
| `WIF_PROVIDER` | Full provider name from step 3 |
| `WIF_SERVICE_ACCOUNT` | `terraform-github-actions@YOUR_PROJECT_ID.iam.gserviceaccount.com` |
| `OBSIDIAN_VAULT_PATH` | `/opt/obsidian-vault` (default) |
| `ENABLE_OBSIDIAN_SYNC` | `true` |
| `ENABLE_MCPVAULT` | `true` |
| `ENABLE_CLAUDE_CLI` | `true` |
| `ENABLE_RUNNER` | `true` |
| `ENABLE_HTTPS` | `true` |
| `DUCKDNS_SUBDOMAIN` | `your-subdomain` (without `.duckdns.org`) |
| `MCPVAULT_USER` | `admin` |

**Secrets** (Settings → Secrets and variables → Actions → Secrets):

| Name | Value |
|------|-------|
| `MCPVAULT_PASSWORD` | Strong password (12+ chars) |
| `DUCKDNS_TOKEN` | Token from duckdns.org |
| `TAILSCALE_AUTH_KEY` | From tailscale.com/admin/settings/keys |

### 5. Deploy

```bash
git push origin master
```

The `infra.yml` workflow runs Terraform and, after a successful apply, automatically triggers `deploy-services.yml` to install all services on the VM. Wait 3–5 minutes for the bootstrap script to complete.

---

## 🖐️ Manual Steps After Deployment

These are **one-time steps per VM**. Only redo if the VM is destroyed and recreated.

### 0. SSH to the VM

```bash
gcloud compute ssh obsidian-vm --zone=us-central1-a --project=YOUR_PROJECT --tunnel-through-iap
```

### 0.1 Check the bootstrap completed successfully

```bash
cat /var/log/obsidian-vm-setup.log
```

Look for `=== Bootstrap Completed` at the end. Then check the service deploy log:

```bash
cat /var/log/obsidian-deploy.log
```

### 1. Tailscale

```bash
tailscale status          # check if already connected
tailscale ip -4           # save this IP for future SSH
```

### 2. Obsidian Sync

```bash
sudo -u obsidian ob login                              # authenticate with your Obsidian account
sudo -u obsidian ob sync-list-remote                   # list your vaults, copy the exact name
cd /opt/obsidian-vault                                 # IMPORTANT: must run setup from vault directory
sudo -u obsidian ob sync-setup --vault "My Vault"      # configure sync at this path
sudo systemctl start obsidian-sync                     # begin continuous sync
journalctl -u obsidian-sync -f                         # watch files appear in /opt/obsidian-vault/
```

### 3. Claude CLI

```bash
claude login    # follow the OAuth flow
```

### 4. obsidian-runner

```bash
sudo systemctl status obsidian-runner   # verify it started automatically
journalctl -u obsidian-runner -f        # watch live logs
```

Place your schedule file at `$VAULT_BASE/00-Inbox/_other/schedules.yaml`. The daemon hot-reloads it every 30 seconds, so you can edit it from any device in Obsidian.

> [!NOTE]
> `call_llm()` in `services/obsidian-runner/obsidian_runner.py` is currently a placeholder. Wire it to the Anthropic SDK to make prompts actually run.

### 5. Connect MCPVault to Claude.ai

1. Claude.ai → Settings → Integrations → **Add MCP server**
2. URL: `https://your-subdomain.duckdns.org/sse`
3. Credentials: your `MCPVAULT_USER` / `MCPVAULT_PASSWORD`

---

## 📄 Prompt File Format

Each prompt is a markdown file with YAML frontmatter. The body is the prompt text sent to the LLM.

```markdown
---
output:
  path: "Daily/journal-output.md"
mode: append        # append | overwrite
model: claude-sonnet-4-6
temperature: 0.7
---

Review my recent journal entries and suggest one reflection question for today.
```

Place these anywhere in your vault and reference their paths in `schedules.yaml`.

---

## ✅ Verification

```bash
# Bootstrap + deploy logs
cat /var/log/obsidian-vm-setup.log
cat /var/log/obsidian-deploy.log

# All service statuses at a glance
systemctl status obsidian-sync mcpvault obsidian-runner caddy

# Vault is populated
ls /opt/obsidian-vault/

# Runner execution log (also visible in Obsidian)
cat /opt/obsidian-vault/00-Inbox/_other/schedules-log.md
```

---

## 🏗️ File Structure

```
obsidian-cloud/
├── .github/workflows/
│   ├── infra.yml               # Terraform plan + apply (triggers on infra/**)
│   ├── deploy-services.yml     # SSH service deploy (triggers on services/**)
│   └── destroy.yml             # Manual destroy with approval gate
├── infra/                      # Terraform — VM, firewall, GCP resources
│   ├── main.tf                 # Compute instance + firewall (bootstrap only)
│   ├── variables.tf            # Infrastructure vars only (no service config)
│   ├── outputs.tf
│   ├── provider.tf
│   ├── backend.tf
│   └── terraform.tfvars.example
├── services/                   # Everything deployed to the VM via CI/CD
│   ├── deploy.sh               # Orchestrator — calls each service's install.sh
│   ├── obsidian-sync/          # Headless Obsidian vault sync
│   ├── mcpvault/               # MCP server exposing vault to Claude.ai
│   ├── obsidian-runner/        # Python scheduled prompt runner
│   ├── caddy/                  # HTTPS reverse proxy (Let's Encrypt + DuckDNS)
│   ├── claude-cli/             # Claude CLI for vault automation
│   └── couchdb/                # CouchDB (disabled — using Obsidian Sync)
├── docs/LEARNINGS.md           # Deep dive: architecture, lessons, gotchas
└── README.md
```

---

## 🩺 Troubleshooting

| Issue | Check |
|-------|-------|
| Bootstrap failed | `cat /var/log/obsidian-vm-setup.log` |
| Service deploy failed | `cat /var/log/obsidian-deploy.log` |
| Vault not syncing | `journalctl -u obsidian-sync -f` — did you run `ob login`? |
| MCPVault unreachable from Claude.ai | `systemctl status mcpvault caddy` — is `ENABLE_HTTPS=true`? |
| Runner not firing | `journalctl -u obsidian-runner -f` — is `schedules.yaml` in the vault? |
| GitHub Actions auth fails | Verify `WIF_PROVIDER` and `WIF_SERVICE_ACCOUNT` values |

---

## 📚 Resources

- [MCPVault](https://github.com/bitbonsai/mcpvault)
- [obsidian-headless](https://www.npmjs.com/package/obsidian-headless)
- [supergateway](https://github.com/supercorp-ai/supergateway)
- [Caddy](https://caddyserver.com/)
- [DuckDNS](https://www.duckdns.org/)
- [Tailscale](https://tailscale.com/)
- [GCP Free Tier](https://cloud.google.com/free)
- [Workload Identity Federation](https://cloud.google.com/iam/docs/workload-identity-federation)
