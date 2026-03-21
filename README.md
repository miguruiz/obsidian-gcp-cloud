# Obsidian Cloud VM

**Terraform + GitHub Actions CI/CD on a GCP free-tier e2-micro VM.**

Modular personal infrastructure for syncing an Obsidian vault to a server, exposing it as an MCP tool for Claude.ai, and running scheduled LLM automations. Each service is independently toggled via feature flags.

**Cost: ~$0/month** within GCP free tier (e2-micro in us-west1, us-central1, or us-east1).

---

## Table of Contents

- [Services](#services)
- [Architecture](#architecture)
- [Setup](#setup)
  - [1. Enable GCP APIs](#1-enable-gcp-apis)
  - [2. Terraform state bucket](#2-create-gcs-bucket-for-terraform-state)
  - [3. Workload Identity Federation](#3-set-up-workload-identity-federation)
  - [4. GitHub variables & secrets](#4-configure-github-repository)
  - [5. Deploy](#5-deploy)
- [Manual Steps After Deployment](#manual-steps-after-deployment)
  - [Obsidian Sync](#obsidian-sync-setup-enable_headless_obsidian)
  - [Claude CLI](#claude-cli-auth-enable_claude_cli)
  - [obsidian_runner](#obsidian_runner-setup-enable_runner)
  - [Connect MCPVault to Claude.ai](#connect-mcpvault-to-claudeai)
- [Prompt File Format](#prompt-file-format)
- [Verification](#verification)
- [File Structure](#file-structure)
- [Troubleshooting](#troubleshooting)

---

## Services

Each service is independently controlled by a GitHub Actions variable (feature flag). All default to `false`.

| Service | Flag | What it does | Dependencies |
|---------|------|--------------|--------------|
| **obsidian-headless** | `ENABLE_HEADLESS_OBSIDIAN` | Continuously pulls vault from Obsidian Sync cloud to `/opt/obsidian-vault/` on the VM | Obsidian Sync subscription; manual `ob login` after deploy |
| **MCPVault** | `ENABLE_MCPVAULT` | Runs an MCP server over your vault so Claude.ai can read/search your notes | `ENABLE_HEADLESS_OBSIDIAN` + `ENABLE_HTTPS` for Claude.ai iOS |
| **Claude CLI** | `ENABLE_CLAUDE_CLI` | Installs `claude` on the VM for cron-based vault automation | Manual `claude login` after deploy |
| **obsidian_runner** | `ENABLE_RUNNER` | Python daemon: reads `schedules.yaml` from vault, fires LLM prompt jobs on cron, writes results back as markdown | `ENABLE_HEADLESS_OBSIDIAN` (vault must exist); manual schedule file setup |
| **HTTPS (Caddy)** | `ENABLE_HTTPS` | Public HTTPS via DuckDNS + Caddy with Let's Encrypt. Required for Claude.ai iOS to reach MCPVault | `DUCKDNS_SUBDOMAIN` + `DUCKDNS_TOKEN` |
| **Tailscale** | `TAILSCALE_AUTH_KEY` (secret) | Private VPN for SSH access without opening port 22 | Tailscale account |
| **CouchDB** | `ENABLE_COUCHDB` | Legacy: self-hosted CouchDB for Obsidian LiveSync plugin | `COUCHDB_PASSWORD` secret |

---

## Architecture

```
Obsidian Sync (cloud)
       │ continuous pull (obsidian-headless systemd service)
       ▼
/opt/obsidian-vault/              ← vault files on disk
       │
       ├── MCPVault (stdio → supergateway → :3000 SSE)
       │       └── Caddy (:443, HTTPS + basicauth, Let's Encrypt)
       │               └── Claude.ai iOS/Web
       │                   (Anthropic's servers connect to your public URL)
       │
       └── obsidian_runner (Python daemon, every 30s)
               reads  00-Inbox/_other/schedules.yaml   ← edit in Obsidian
               writes 00-Inbox/_other/schedules-log.md ← visible in Obsidian
               runs prompt files → writes LLM output back to vault
```

---

## Setup

### 1. Enable GCP APIs

```bash
export PROJECT_ID="your-project-id"
gcloud services enable compute.googleapis.com iam.googleapis.com \
  cloudresourcemanager.googleapis.com iamcredentials.googleapis.com \
  sts.googleapis.com --project=$PROJECT_ID
```

### 2. Create GCS bucket for Terraform state

```bash
export BUCKET_NAME="obsidian-tfstate-$(openssl rand -hex 4)"
gsutil mb -p $PROJECT_ID -l us-central1 -b on gs://$BUCKET_NAME
gsutil versioning set on gs://$BUCKET_NAME
```

Update `backend.tf` with your bucket name.

### 3. Set up Workload Identity Federation

Allows GitHub Actions to authenticate to GCP without long-lived keys.

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

# Allow GitHub to impersonate the SA
export PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format="value(projectNumber)")

gcloud iam service-accounts add-iam-policy-binding \
  terraform-github-actions@$PROJECT_ID.iam.gserviceaccount.com \
  --project=$PROJECT_ID \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/github-actions-pool/attribute.repository/YOUR_GITHUB_USERNAME/YOUR_REPO_NAME"

# Save this — you'll need it for WIF_PROVIDER
gcloud iam workload-identity-pools providers describe github-provider \
  --project=$PROJECT_ID --location="global" \
  --workload-identity-pool="github-actions-pool" \
  --format="value(name)"
```

### 4. Configure GitHub repository

**Variables** (Settings → Secrets and variables → Actions → Variables):

| Name | Value |
|------|-------|
| `GCP_PROJECT_ID` | Your GCP project ID |
| `WIF_PROVIDER` | Full provider name from step 3 |
| `WIF_SERVICE_ACCOUNT` | `terraform-github-actions@YOUR_PROJECT_ID.iam.gserviceaccount.com` |
| `OBSIDIAN_VAULT_PATH` | `/opt/obsidian-vault` (default) |
| `ENABLE_HEADLESS_OBSIDIAN` | `true` |
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

Watch the Actions workflow. Wait 3–5 min for the startup script to complete.

---

## Manual Steps After Deployment

SSH to the VM first:
```bash
gcloud compute ssh obsidian-couchdb-vm --zone=us-central1-a
# or via Tailscale: ssh root@<tailscale-ip>
```

### Obsidian Sync setup (`ENABLE_HEADLESS_OBSIDIAN`)

```bash
ob login                              # opens browser — authenticate with your Obsidian account
ob sync-list-remote                   # list your vaults — copy the exact name
ob sync-setup --vault "Your Vault"    # connect vault to this VM path
systemctl start obsidian-sync         # begin continuous sync
journalctl -u obsidian-sync -f        # watch files appear in /opt/obsidian-vault/
```

### Claude CLI auth (`ENABLE_CLAUDE_CLI`)

```bash
claude login    # follow the OAuth flow
```

### obsidian_runner setup (`ENABLE_RUNNER`)

The daemon reads its schedule from inside the vault. After obsidian-sync is running:

```bash
systemctl status obsidian-runner      # verify it started
journalctl -u obsidian-runner -f      # watch live logs
```

Place your schedule file at `$VAULT_BASE/00-Inbox/_other/schedules.yaml` — copy `runner/schedules.yaml` from this repo as a starting point. The daemon hot-reloads it every 30 seconds, so you can edit it from any device in Obsidian.

Execution results appear at `00-Inbox/_other/schedules-log.md`, visible in Obsidian.

> **Note:** `call_llm()` in `runner/obsidian_runner.py` is currently a placeholder. Wire it to the Anthropic SDK to make prompts actually run.

### Connect MCPVault to Claude.ai

1. Claude.ai → Settings → Integrations → Add MCP server
2. URL: `https://your-subdomain.duckdns.org/sse`
3. Credentials: your `MCPVAULT_USER` / `MCPVAULT_PASSWORD`

---

## Prompt File Format

Each prompt is a markdown file with YAML frontmatter. The body is the prompt text.

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

## Verification

```bash
# Startup script logs
cat /var/log/obsidian-vm-setup.log

# All service statuses
systemctl status obsidian-sync mcpvault obsidian-runner caddy

# Vault is populated
ls /opt/obsidian-vault/

# Runner log (also visible in Obsidian)
cat /opt/obsidian-vault/00-Inbox/_other/schedules-log.md
```

---

## File Structure

```
obsidian-cloud/
├── .github/workflows/deploy.yml   # CI/CD pipeline
├── main.tf                        # VM + startup script (all services)
├── variables.tf                   # Feature flags + config vars
├── outputs.tf                     # Terraform outputs
├── provider.tf / backend.tf       # Terraform config
├── terraform.tfvars.example       # Example values (don't commit real values)
├── runner/
│   ├── obsidian_runner.py         # Python daemon source
│   ├── requirements.txt           # pyyaml, croniter, python-frontmatter
│   ├── schedules.yaml             # Example schedule (copy to vault)
│   └── obsidian_runner.service    # Reference systemd unit
├── docs/LEARNINGS.md              # Deep dive: architecture, lessons, gotchas
└── README.md
```

---

## Troubleshooting

| Issue | Check |
|-------|-------|
| Startup script failed | `cat /var/log/obsidian-vm-setup.log` |
| Vault not syncing | `journalctl -u obsidian-sync -f` — did you run `ob login`? |
| MCPVault unreachable from Claude.ai | `systemctl status mcpvault caddy` — is `ENABLE_HTTPS=true`? |
| Runner not firing | `journalctl -u obsidian-runner -f` — is `schedules.yaml` in the vault? |
| GitHub Actions auth fails | Verify `WIF_PROVIDER` and `WIF_SERVICE_ACCOUNT` values |

---

## Resources

- [MCPVault](https://github.com/bitbonsai/mcpvault)
- [obsidian-headless](https://www.npmjs.com/package/obsidian-headless)
- [supergateway](https://github.com/supercorp-ai/supergateway)
- [Caddy](https://caddyserver.com/)
- [DuckDNS](https://www.duckdns.org/)
- [Tailscale](https://tailscale.com/)
- [GCP Free Tier](https://cloud.google.com/free)
- [Workload Identity Federation](https://cloud.google.com/iam/docs/workload-identity-federation)
