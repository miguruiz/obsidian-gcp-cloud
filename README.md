# Obsidian Cloud

Personal GCP VM running Obsidian Sync + MCPVault — making your vault accessible to Claude.ai from anywhere.

---

## TODO

- [ ] Follow manual steps (see [Manual Setup](#manual-setup) below)
- [ ] Test the MCP from Claude

---

## Architecture

| Layer | What | How | Trigger |
|-------|------|-----|---------|
| **Infrastructure** | VM, firewall, GCP resources | Terraform | `infra/**` changes |
| **Services** | CLIs, Python daemons, systemd units | `services/deploy.sh` via IAP SSH | `services/**` changes |
| **Environment** | Tailscale auth, `claude login`, `ob login` | Manual (one-time) | VM recreation only |

```
obsidian-cloud/
├── infra/                    # Terraform — VM, firewall, GCP resources
│   ├── main.tf               # Compute instance + firewall rules
│   ├── variables.tf          # Infrastructure variables (not service config)
│   ├── outputs.tf
│   ├── provider.tf
│   └── backend.tf
├── services/                 # Everything deployed to the VM via CI/CD
│   ├── deploy.sh             # Orchestrator — calls each service's install.sh
│   ├── obsidian-sync/        # Headless Obsidian vault sync
│   ├── mcpvault/             # MCP server exposing vault to Claude.ai
│   ├── obsidian-runner/      # Python scheduled prompt runner
│   ├── caddy/                # HTTPS reverse proxy (Let's Encrypt + DuckDNS)
│   ├── claude-cli/           # Claude CLI for vault automation
│   └── couchdb/              # CouchDB (disabled — using Obsidian Sync instead)
└── .github/workflows/
    ├── infra.yml             # Terraform plan + apply
    ├── deploy-services.yml   # SSH service deploy
    └── destroy.yml           # Manual destroy with approval
```

---

## CI/CD Workflows

**Push to `infra/**`** → `infra.yml` runs Terraform → on apply, auto-triggers `deploy-services.yml`

**Push to `services/**`** → `deploy-services.yml` SSHs into VM and runs `deploy.sh`

**Adding a new service** (no VM recreation needed):
1. Add a folder under `services/` with `install.sh` + systemd unit
2. Add feature flag to `deploy-services.yml` env vars
3. Call it from `deploy.sh`
4. Push → CI deploys it

---

## GitHub Variables & Secrets

### Variables (`Settings → Secrets and variables → Actions → Variables`)

| Variable | Description |
|----------|-------------|
| `GCP_PROJECT_ID` | GCP project ID |
| `GCP_ZONE` | VM zone (default: `us-central1-a`) |
| `WIF_PROVIDER` | Workload Identity Federation provider resource name |
| `WIF_SERVICE_ACCOUNT` | Terraform service account email |
| `ENABLE_OBSIDIAN_SYNC` | `true/false` |
| `ENABLE_MCPVAULT` | `true/false` |
| `ENABLE_CLAUDE_CLI` | `true/false` |
| `ENABLE_RUNNER` | `true/false` |
| `ENABLE_HTTPS` | `true/false` |
| `ENABLE_COUCHDB` | `true/false` (default: false) |
| `DUCKDNS_SUBDOMAIN` | Your DuckDNS subdomain (without `.duckdns.org`) |
| `MCPVAULT_USER` | Basic auth username (default: `admin`) |
| `OBSIDIAN_VAULT_PATH` | Vault path on VM (default: `/opt/obsidian-vault`) |

### Secrets (`Settings → Secrets and variables → Actions → Secrets`)

| Secret | Description |
|--------|-------------|
| `TAILSCALE_AUTH_KEY` | Tailscale auth key (for VM bootstrap) |
| `DUCKDNS_TOKEN` | DuckDNS token |
| `MCPVAULT_PASSWORD` | Basic auth password for MCPVault (min 12 chars) |
| `COUCHDB_PASSWORD` | CouchDB password (only if `ENABLE_COUCHDB=true`) |

---

## GCP / WIF Setup (one-time)

```bash
# 1. Create Workload Identity Pool
gcloud iam workload-identity-pools create "github-actions-pool" \
  --location="global" \
  --display-name="GitHub Actions Pool"

# 2. Create OIDC Provider
gcloud iam workload-identity-pools providers create-oidc "github-provider" \
  --location="global" \
  --workload-identity-pool="github-actions-pool" \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.repository_owner=assertion.repository_owner" \
  --attribute-condition="assertion.repository_owner == 'YOUR_GITHUB_USERNAME'" \
  --issuer-uri="https://token.actions.githubusercontent.com"

# 3. Create Terraform service account
gcloud iam service-accounts create terraform-github-actions \
  --display-name="Terraform GitHub Actions"

# 4. Grant permissions
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:terraform-github-actions@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/compute.admin"

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:terraform-github-actions@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/storage.admin"

# 5. IAP tunnel access (required for gcloud compute ssh --tunnel-through-iap from CI)
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:terraform-github-actions@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/iap.tunnelResourceAccessor"

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:terraform-github-actions@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/compute.instanceAdmin.v1"

# 6. Allow GitHub Actions to impersonate the service account
gcloud iam service-accounts add-iam-policy-binding \
  terraform-github-actions@$PROJECT_ID.iam.gserviceaccount.com \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/github-actions-pool/attribute.repository/YOUR_GITHUB_USERNAME/YOUR_REPO_NAME"

# 7. Get WIF_PROVIDER value for GitHub variable
gcloud iam workload-identity-pools providers describe github-provider \
  --location="global" \
  --workload-identity-pool="github-actions-pool" \
  --format="value(name)"
```

---

## Manual Setup

These steps are only needed after the **first VM creation** (or recreation via `terraform destroy`).

```bash
# SSH into the VM
gcloud compute ssh obsidian-vm --zone=us-central1-a --project=YOUR_PROJECT --tunnel-through-iap

# 1. Obsidian Sync — log in and connect vault
sudo -u obsidian ob login
sudo -u obsidian ob sync-list-remote   # find your vault name
cd /opt/obsidian-vault && sudo -u obsidian ob sync-setup --vault 'Your Vault Name'
sudo systemctl start obsidian-sync
sudo journalctl -u obsidian-sync -f    # verify syncing

# 2. Claude CLI — log in
claude login
```

---

## Adding Claude.ai MCP Integration

Once deployed with `ENABLE_MCPVAULT=true` and `ENABLE_HTTPS=true`:

1. Open Claude.ai → Settings → Integrations → Add MCP server
2. URL: `https://YOUR_SUBDOMAIN.duckdns.org/sse`
3. Auth: basic auth with `MCPVAULT_USER` / `MCPVAULT_PASSWORD`
