# Understanding Your Obsidian Cloud Setup

*A deep dive into how this whole thing works, why we built it this way, and what you can learn from it.*

---

## The Big Picture: What Are We Even Doing Here?

Imagine you have notes in Obsidian on your laptop. You also have Obsidian on your phone. You want Claude.ai to be able to read and reason over those notes — and you want cron jobs on a server to run AI prompts against them automatically.

**The v2 stack** (current):
- **Obsidian Sync** (paid) handles device-to-device sync — Obsidian's own cloud, end-to-end encrypted, fast
- **obsidian-headless** runs on the VM and continuously pulls the vault down from Obsidian's cloud into `/opt/obsidian-vault/` on disk
- **MCPVault** reads those files and exposes them as an MCP server
- **Caddy** puts it behind public HTTPS so Claude.ai iOS can reach it (Anthropic's servers need to connect to your endpoint)
- **Claude CLI** runs on the VM so cron jobs can fire AI prompts directly against the vault
- **obsidian_runner** (new) — a Python daemon that reads `schedules.yaml` from your vault, runs LLM prompt files on cron schedules, and writes results back into the vault as markdown

**The v1 stack** (legacy, now optional):
- Self-hosted CouchDB in a Docker container, synced to Obsidian via the LiveSync plugin

You can still run v1 — it's controlled by a feature flag. But the default is now v2.

---

## Architecture: The Full Picture

```
Obsidian Cloud (Obsidian Sync)
        │
        │ continuous sync (obsidian-headless)
        ▼
/opt/obsidian-vault/   ←──────────────────────────────────┐
        │                                                  │
        │ reads files                           cron jobs  │
        ▼                                          │       │
MCPVault (stdio)                        claude CLI ─┘       │
        │                                                  │
        │ supergateway wraps to :3000 (SSE)                │
        ▼                                                  │
Caddy (:443, public HTTPS)                                 │
  basicauth in front                                       │
        │                                                  │
        ▼                                                  │
Claude.ai iOS / Web / Desktop ─────────────────────────────┘
(Anthropic's servers connect to your VM's public HTTPS URL)
```

All of this lives on a **free-tier GCP e2-micro VM**. Terraform manages the infrastructure. GitHub Actions deploys on every push.

---

## Why We Switched from CouchDB to Obsidian Sync

CouchDB was a self-hosted database we ran in Docker to sync Obsidian vaults between devices. It worked, but:

1. **Complexity**: Docker on a tiny VM, CORS configuration, health checks, managing a database
2. **Reliability**: CouchDB occasionally needed restarts, manual intervention
3. **The real goal shifted**: We don't need device sync from the server anymore — Obsidian Sync handles that natively. We needed the vault *on the server* for AI access, not as a sync hub.

Obsidian Sync + headless is simpler: Obsidian's cloud is the source of truth, the VM is just a read-only consumer.

CouchDB is still available via `enable_couchdb = true` — maybe you want it for other reasons. The feature flag system means both can coexist.

---

## The Feature Flag System

This is one of the most useful patterns in this codebase. Instead of having separate Terraform files for different configurations, every service is a boolean variable:

```hcl
variable "enable_mcpvault" {
  type    = bool
  default = false
}
```

In the startup script, each service is wrapped in a shell conditional:

```bash
ENABLE_MCPVAULT='${var.enable_mcpvault}'   # Terraform injects true/false at apply time

if [ "$ENABLE_MCPVAULT" = "true" ]; then
  npm install -g @bitbonsai/mcpvault supergateway
  # ... install systemd unit, start service
fi
```

This means:
- **One codebase** handles all configurations
- **GitHub variables** control what's actually running (no code changes needed to toggle services)
- **Nothing installs unless needed**: if `enable_couchdb = false`, Docker is never installed. The VM is lighter.
- **Easy to reason about**: `terraform plan` shows exactly what changes

The variables flow: GitHub Variables/Secrets → `TF_VAR_*` environment variables → Terraform `var.*` → shell variables in startup script → conditional `if` blocks.

---

## The MCP + Claude.ai iOS Problem (and Solution)

This tripped us up conceptually early on. Here's the mental model:

**MCP (Model Context Protocol)** is how Claude reads external tools/data. There are two transport modes:
1. **stdio**: Claude spawns a subprocess locally, talks to it via stdin/stdout. Used for local tools (like when you're running Claude Desktop on your laptop).
2. **SSE (Server-Sent Events)**: Claude connects to an HTTP endpoint. Required for remote servers.

**The Claude.ai iOS problem**: When you add an MCP server in Claude.ai on your iPhone, it's not YOUR phone connecting to your server. It's **Anthropic's servers** connecting to your server on behalf of your session. This means:
- Tailscale won't work (Anthropic can't join your VPN)
- Localhost won't work
- You need a **public HTTPS URL** that anyone on the internet can reach

**The solution**:
- MCPVault runs locally on the VM (stdio mode internally)
- `supergateway` wraps it and exposes port 3000 as an SSE endpoint
- Caddy sits in front with basicauth + Let's Encrypt HTTPS
- Result: `https://your-subdomain.duckdns.org/sse` — a public, authenticated, HTTPS MCP endpoint

The Claude CLI on the VM (for cron jobs) uses MCPVault in the OTHER mode — stdio directly. The `~/.claude.json` config tells it to spawn `npx @bitbonsai/mcpvault /opt/obsidian-vault` as a local subprocess. No network involved. Fast, simple.

---

## Security Model

**MCPVault has no built-in auth**. Anyone who can reach port 3000 can read your vault. That's why:
1. Port 3000 is NOT in the GCP firewall rules — only ports 443 (and optionally 22 via SSH rule) are open
2. Caddy's `basicauth` gates everything at the HTTPS layer
3. Passwords are hashed with bcrypt by Caddy's built-in `caddy hash-password` command

**Tailscale** is still there for SSH access. It's a private VPN — even if you have no firewall rules for port 22, you can SSH to the VM via its Tailscale IP. This is the recommended way to access the VM for the manual setup steps.

**Defense in depth**:
- GCP firewall: only port 443 open to the world
- Caddy basicauth: password-protects the MCP endpoint
- Obsidian vault: your notes stay encrypted in transit, readable only on the VM disk
- Tailscale: private SSH without exposing port 22

---

## The Startup Script Deep Dive

The startup script runs once when the VM first boots (or when the VM is recreated). Terraform injects variables using `${'${var.name}'}` syntax — these are Terraform template interpolations that get resolved at `terraform apply` time, before the script ever touches the VM.

```bash
ENABLE_MCPVAULT='${var.enable_mcpvault}'   # becomes: ENABLE_MCPVAULT='true'
```

The tricky part: **nested heredocs in a Terraform heredoc**. Terraform uses `<<-SCRIPT ... SCRIPT` to define the startup script. Inside that, we write systemd unit files using bash heredocs like `<<MCPVAULT_UNIT ... MCPVAULT_UNIT`. The inner terminator must be at column 0, must use a different name than `SCRIPT`, and variables in the inner heredoc expand at bash runtime (when the script runs on the VM), which is exactly what we want for baking in paths like `$VAULT_PATH`.

**Key pattern**: Variables set at Terraform time (like the feature flags, passwords, domain names) are injected as string literals. Variables derived at runtime (like `$EXTERNAL_IP` from the GCP metadata API, `$MCPVAULT_HASH` from `caddy hash-password`) are computed when the script runs on the VM.

---

## The Caddy Config Gets Interesting

Caddy's config varies based on which services are enabled. Three cases:

**MCPVault only** (most common):
```
your-domain.duckdns.org {
    basicauth /* { ... }
    reverse_proxy localhost:3000
}
```

**MCPVault + CouchDB** (both enabled):
```
your-domain.duckdns.org {
    basicauth /mcp/* { ... }
    handle /mcp/* {
        uri strip_prefix /mcp
        reverse_proxy localhost:3000
    }
    handle {
        reverse_proxy localhost:5984
    }
}
```

**CouchDB only** (legacy mode):
```
your-domain.duckdns.org {
    reverse_proxy localhost:5984
}
```

The logic lives in the startup script — shell `if/else` blocks that write different Caddyfile content. Caddy is then started after the config is written.

---

## Obsidian Headless: The "Enable But Don't Start" Pattern

`obsidian-sync.service` is installed by the startup script but **not started**. This is intentional.

The headless Obsidian tool needs you to authenticate with your Obsidian account first (`ob login`). That's an interactive step — it gives you a URL to visit and authenticate. You can't automate it in a startup script.

So the pattern is:
1. Startup script installs the tool, creates the systemd unit, runs `systemctl enable` (so it'll start automatically on reboot after setup)
2. You SSH to the VM, run `ob login`, `ob sync-setup --vault "Name"`, then `systemctl start obsidian-sync`
3. The vault starts syncing continuously. After a reboot, the service starts automatically.

Same pattern for `claude login` — Claude CLI is installed, but you need to authenticate interactively. The startup script logs a reminder.

---

## Lessons and Gotchas

### The MCP Transport Mode Confusion

We initially thought Tailscale would work for Claude.ai iOS. It doesn't. The distinction between "who's connecting" (your device vs. Anthropic's servers) is easy to miss. When in doubt: **if you need AI-as-a-service to connect to your server, it must be public HTTPS**.

### Terraform 1.9 Cross-Variable Validation

Terraform 1.7 didn't support referencing other variables inside `validation` blocks. In 1.9, this was added. We upgraded from 1.7 to 1.9 specifically to enable cleaner validation logic like:

```hcl
validation {
  condition     = !var.enable_mcpvault || length(var.mcpvault_password) >= 12
  error_message = "mcpvault_password must be at least 12 characters when enable_mcpvault = true."
}
```

This is much better than the alternative (no validation, or duplicating logic in scripts).

### Caddy's `basicauth` Requires Bcrypt Hashes

You can't put a plaintext password in a Caddyfile. Caddy requires bcrypt-hashed passwords. The startup script uses `caddy hash-password --plaintext "$MCPVAULT_PASSWORD"` to generate the hash at deploy time, then bakes it into the Caddyfile. This means the plaintext password never touches the Caddyfile — only the hash.

### supergateway Wraps stdio → SSE

`supergateway` is the glue between MCPVault (which speaks MCP over stdio) and the HTTP world (SSE). You give it a command to run as a subprocess (`npx @bitbonsai/mcpvault /vault/path`), and it wraps that subprocess behind an HTTP SSE endpoint on a port you specify. This is a general pattern for taking any stdio MCP server and making it available over the network.

### The VM Name Dilemma

We kept the VM named `obsidian-couchdb-vm` even after removing CouchDB as the default. Why? Because Terraform treats a name change as "destroy old VM, create new VM" — which would destroy your disk and cause downtime. For a personal VM that's annoying. Rename it only if you're okay with recreation (e.g., you have no persistent state to preserve).

### Startup Scripts Run Once

GCP startup scripts run on every boot, not just the first one. This means your startup script needs to be **idempotent** — running it twice shouldn't break anything. Patterns we use:
- `docker stop ... 2>/dev/null || true` (ignore errors if container doesn't exist)
- `systemctl enable` is idempotent by nature
- `npm install -g` overwrites existing installations

---

## Manual Steps After Deployment

The startup script handles everything it can automate. These steps require you:

1. **SSH to VM**: `gcloud compute ssh obsidian-couchdb-vm --zone=us-central1-a`
2. **Authenticate Obsidian Sync**: `ob login` → visit the URL → log in with your Obsidian account
3. **Find your vault**: `ob sync-list-remote` → copy the vault name exactly
4. **Connect vault to VM**: `ob sync-setup --vault "Your Vault Name"`
5. **Start syncing**: `systemctl start obsidian-sync`
6. **Watch it work**: `journalctl -u obsidian-sync -f` → files should appear in `/opt/obsidian-vault/`
7. **Authenticate Claude**: `claude login` → follow the OAuth flow
8. **Test MCPVault cron**: `claude --dangerously-skip-permissions -p "list my 5 most recent notes"`
9. **Add to Claude.ai**: Settings → Integrations → Add MCP server → `https://your-subdomain.duckdns.org/sse`

---

## GitHub Secrets/Variables to Configure

| Name | Type | Value |
|------|------|-------|
| `ENABLE_HEADLESS_OBSIDIAN` | Variable | `true` |
| `ENABLE_MCPVAULT` | Variable | `true` |
| `ENABLE_CLAUDE_CLI` | Variable | `true` |
| `ENABLE_COUCHDB` | Variable | `false` |
| `ENABLE_RUNNER` | Variable | `true` |
| `ENABLE_HTTPS` | Variable | `true` |
| `DUCKDNS_SUBDOMAIN` | Variable | `your-subdomain` |
| `MCPVAULT_USER` | Variable | `admin` |
| `MCPVAULT_PASSWORD` | Secret | 12+ char strong password |
| `DUCKDNS_TOKEN` | Secret | from duckdns.org |
| `TAILSCALE_AUTH_KEY` | Secret | from tailscale.com/admin |

---

## What You've Learned

By working through this project (v1 and v2), you've touched:

1. **Terraform** — Infrastructure as code, feature flag variables, cross-variable validation (v1.9+), state management
2. **GCP** — VMs, firewall rules, IAM, Workload Identity Federation, startup scripts
3. **MCP (Model Context Protocol)** — stdio vs SSE transports, how Claude.ai iOS connects to remote servers
4. **supergateway** — Wrapping stdio MCP servers as SSE HTTP endpoints
5. **Caddy** — Automatic HTTPS, reverse proxying, basicauth with bcrypt, path-based routing
6. **systemd** — Writing service units, enable vs start, journalctl
7. **GitHub Actions** — CI/CD, OIDC authentication, environment secrets/variables
8. **Security thinking** — Defense in depth, why Tailscale isn't enough for Claude.ai iOS, bcrypt for passwords
9. **Python daemon patterns** — Hot-reloading config, cron scheduling with `croniter`, writing markdown logs, systemd service management
10. **python-frontmatter** — Reading YAML frontmatter from markdown files, a clean pattern for "prompt files with metadata"

---

## The obsidian_runner: A Vault-Native Scheduler

The runner is a Python daemon (`obsidian_runner.py`) that wakes up every 30 seconds, re-reads `schedules.yaml` from your vault, and fires LLM jobs according to cron schedules. Results are written back as markdown files in the vault — so everything is visible and editable in Obsidian itself.

**Why this design is clever:**

The schedule configuration lives at `$VAULT_BASE/00-Inbox/_other/schedules.yaml` — *inside the vault*. This means you can edit your job schedule from any device (phone, laptop, tablet) via Obsidian, and the daemon picks up the changes within 30 seconds. No SSH, no config file editing, no redeployment. The vault is both the config store and the output store.

**Each prompt is a markdown file with frontmatter:**

```markdown
---
output:
  path: "Daily/journal-output.md"
mode: append
model: claude-sonnet-4-6
temperature: 0.7
---

Review my recent journal entries and suggest one reflection question for today.
```

The frontmatter is metadata (where to write, what model, what mode). The body is the prompt. `python-frontmatter` parses these cleanly. `append` mode prepends a `---\n*YYYY-MM-DD HH:MM*\n\n` separator so multiple runs accumulate as readable sections.

**The `call_llm()` function is currently a placeholder** — it logs a message and returns a dummy string. To make it real, replace it with an Anthropic API call using the `anthropic` Python SDK. The frontmatter `model` and `temperature` fields are already wired up.

**Hot-reload**: `load_schedule()` re-reads the YAML on every loop iteration. If the file is missing, it returns `[]` gracefully — no crash, no noise. Add or disable jobs in Obsidian, and the daemon adapts.

**Execution log**: `schedules-log.md` in the vault is appended after each job run with a block like:
```markdown
## 2026-03-21 08:00 -- morning-routine OK
- `Prompts/morning/journal.md` OK
- `Prompts/morning/tasks.md` OK
- `Prompts/morning/focus.md` FAIL (file not found)
```

Also visible in Obsidian. No need to SSH to check what ran.

**Single-quoted heredoc trick**: The Python script is embedded in the startup script using `<<'RUNNER_SCRIPT'` (note the single quotes). This tells bash to NOT expand any `$variables` inside the heredoc. Without the single quotes, `$VAULT_BASE` in the Python source would get replaced by the shell variable (which doesn't exist in that context), breaking the script. The systemd unit uses `<<RUNNER_UNIT` (no quotes) specifically because we DO want `$VAULT_PATH` to expand there.

---

*The best infrastructure is the one you understand — and can turn off in a single variable change.*
