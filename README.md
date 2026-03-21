# Obsidian Cloud VM

**Terraform + GitHub Actions CI/CD on a GCP free-tier e2-micro VM.**

A modular personal infrastructure for syncing your Obsidian vault to a server and exposing it as an MCP server for Claude.ai, with optional scheduled LLM automation.

## Cost

**~$0/month** within GCP free tier (e2-micro in us-west1, us-central1, or us-east1 only).

---

## Architecture

```
Obsidian Sync (cloud)
       │ continuous sync (obsidian-headless)
       ▼
/opt/obsidian-vault/
       │
       ├── MCPVault (:3000 SSE via supergateway)
       │       └── Caddy (:443 HTTPS + basicauth)
       │               └── Claude.ai iOS / Web ← Anthropic's servers connect here
       │
       └── obsidian_runner (Python daemon)
               reads  schedules.yaml   ← edit from any device in Obsidian
               writes schedules-log.md ← visible in Obsidian
```

All services are feature-flag controlled. Enable only what you need.

---

## Feature Flags

| GitHub Variable | Default | What it does |
|----------------|---------|--------------|
| `ENABLE_HEADLESS_OBSIDIAN` | `false` | Continuously syncs vault from Obsidian Sync to VM |
| `ENABLE_MCPVAULT` | `false` | Runs MCPVault as public MCP server (requires `ENABLE_HTTPS=true` for Claude.ai iOS) |
| `ENABLE_CLAUDE_CLI` | `false` | Installs Claude CLI for cron-based vault automation |
| `ENABLE_RUNNER` | `false` | Installs the Python scheduled prompt runner daemon |
| `ENABLE_HTTPS` | `false` | Sets up Caddy + DuckDNS for public HTTPS |
| `ENABLE_COUCHDB` | `false` | Legacy: CouchDB for Obsidian LiveSync |

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

```bash
# Create pool and OIDC provider
gcloud iam workload-identity-pools create "github-actions-pool" \
  --project=$PROJECT_ID --location="global"

gcloud iam workload-identity-pools providers create-oidc "github-provider" \
  --project=$PROJECT_ID --location="global" \
  --workload-identity-pool="github-actions-pool" \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.repository_owner=assertion.repository_owner" \
  --attribute-condition="assertion.repository_owner == 'YOUR_GITHUB_USERNAME'" \
  --issuer-uri="https://token.actions.githubusercontent.com"

# Create service account and grant permissions
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

# Get the provider name (needed for GitHub variable)
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

Watch the Actions workflow. Wait 3–5 minutes for the startup script to complete.

---

## Manual Steps After Deployment

SSH to the VM first:
```bash
gcloud compute ssh obsidian-couchdb-vm --zone=us-central1-a
# or via Tailscale: ssh root@<tailscale-ip>
```

### Obsidian Sync setup (required for `enable_headless_obsidian`)

```bash
ob login                              # opens browser to authenticate
ob sync-list-remote                   # find your vault name
ob sync-setup --vault "Your Vault"    # connect it
systemctl start obsidian-sync         # begin continuous sync
journalctl -u obsidian-sync -f        # watch files appear
```

### Claude CLI auth (required for `enable_claude_cli`)

```bash
claude login    # OAuth flow
```

### obsidian_runner setup (required for `enable_runner`)

The runner reads its schedule from inside your vault. After obsidian-sync is running:

```bash
# Create the config directory if it doesn't exist yet
mkdir -p /opt/obsidian-vault/00-Inbox/_other

# Copy the example schedule (or create your own)
# Place it at: /opt/obsidian-vault/00-Inbox/_other/schedules.yaml
```

You can also drop `runner/schedules.yaml` from this repo into your vault via Obsidian and edit it from any device. The daemon hot-reloads it every 30 seconds.

**Check runner status:**
```bash
systemctl status obsidian-runner
journalctl -u obsidian-runner -f
cat /opt/obsidian-vault/00-Inbox/_other/schedules-log.md
```

**Note:** `call_llm()` in `obsidian_runner.py` is a placeholder. Wire it to the Anthropic SDK to make it real.

### Add MCPVault to Claude.ai

1. Claude.ai → Settings → Integrations → Add MCP server
2. URL: `https://your-subdomain.duckdns.org/sse`
3. Auth: basic auth with your `MCPVAULT_USER` / `MCPVAULT_PASSWORD`

---

## Prompt File Format

Prompt files are markdown with YAML frontmatter:

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

Place them anywhere in your vault and reference them in `schedules.yaml`.

---

## Verification

```bash
# Startup script logs
cat /var/log/obsidian-vm-setup.log

# Service statuses
systemctl status obsidian-sync mcpvault obsidian-runner caddy

# Vault is being populated
ls /opt/obsidian-vault/

# Runner is firing jobs
journalctl -u obsidian-runner -f
```

---

## File Structure

```
obsidian-cloud/
├── .github/workflows/deploy.yml   # CI/CD pipeline
├── main.tf                        # VM + startup script
├── variables.tf                   # Feature flags + config vars
├── outputs.tf                     # Terraform outputs
├── provider.tf / backend.tf       # Terraform config
├── terraform.tfvars.example       # Example values (don't commit real values)
├── runner/
│   ├── obsidian_runner.py         # Python daemon source
│   ├── requirements.txt           # pyyaml, croniter, python-frontmatter
│   ├── schedules.yaml             # Example schedule (copy to vault)
│   └── obsidian_runner.service    # Reference systemd unit
├── README.md
└── FOR_miguruiz.md                # Deep dive: architecture, lessons, gotchas
```

---

## Troubleshooting

| Issue | Check |
|-------|-------|
| Startup script failed | `cat /var/log/obsidian-vm-setup.log` |
| Vault not syncing | `journalctl -u obsidian-sync -f` — did you run `ob login`? |
| MCPVault unreachable | `systemctl status mcpvault caddy` — is HTTPS enabled? |
| Runner not firing jobs | `journalctl -u obsidian-runner -f` — is `schedules.yaml` in the vault? |
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
