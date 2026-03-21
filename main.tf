# =============================================================================
# main.tf - Core infrastructure for Obsidian Cloud VM
# =============================================================================
# GCP e2-micro VM (free-tier eligible) running modular services controlled
# by feature flag variables. Services: CouchDB, MCPVault, Obsidian Headless,
# Claude CLI, Tailscale, HTTPS (Caddy + DuckDNS).
# =============================================================================

# -----------------------------------------------------------------------------
# Firewall Rules
# -----------------------------------------------------------------------------

# CouchDB access firewall rule
# Only created if allowed_ips is not empty. Use HTTPS or Tailscale for secure access.
resource "google_compute_firewall" "allow_couchdb" {
  count   = length(var.allowed_ips) > 0 ? 1 : 0
  name    = "allow-couchdb-5984"
  network = "default"
  project = var.project_id

  description = "Allow CouchDB access on port 5984 from specific IPs only"

  allow {
    protocol = "tcp"
    ports    = ["5984"]
  }

  # Source ranges - only specific IPs, never 0.0.0.0/0
  source_ranges = var.allowed_ips

  target_tags = ["couchdb-server"]

  # Log connections for security auditing (optional, may incur small cost)
  # log_config {
  #   metadata = "INCLUDE_ALL_METADATA"
  # }
}

# SSH access firewall rule (optional, for debugging)
# Only enabled if ssh_allowed_ips is not empty
resource "google_compute_firewall" "allow_ssh" {
  count   = length(var.ssh_allowed_ips) > 0 ? 1 : 0
  name    = "allow-ssh-couchdb-vm"
  network = "default"
  project = var.project_id

  description = "Allow SSH access to CouchDB VM for administration"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = var.ssh_allowed_ips
  target_tags   = ["couchdb-server"]
}

# HTTPS access firewall rule (for Caddy reverse proxy)
# Only enabled if enable_https is true
resource "google_compute_firewall" "allow_https" {
  count   = var.enable_https ? 1 : 0
  name    = "allow-https-couchdb-vm"
  network = "default"
  project = var.project_id

  description = "Allow HTTPS access for Caddy reverse proxy (required for mobile Obsidian)"

  allow {
    protocol = "tcp"
    ports    = ["443"]
  }

  source_ranges = ["0.0.0.0/0"] # HTTPS is public by design
  target_tags   = ["couchdb-server"]
}

# -----------------------------------------------------------------------------
# Compute Instance - CouchDB Server
# -----------------------------------------------------------------------------

resource "google_compute_instance" "obsidian_couchdb_vm" {
  name         = "obsidian-couchdb-vm"
  machine_type = "e2-micro" # Free-tier eligible (1 per month in eligible regions)
  zone         = var.zone
  project      = var.project_id

  # Tags for firewall rules
  tags = ["couchdb-server"]

  # Boot disk configuration
  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12" # Stable, lightweight
      size  = 30                       # GB - free tier allows up to 30GB pd-standard
      type  = "pd-standard"            # Standard persistent disk (free tier)
    }
    auto_delete = true
  }

  # Network configuration with ephemeral external IP
  network_interface {
    network = "default"

    # Ephemeral external IP for public access
    # Consider removing this and using Tailscale for private-only access
    access_config {
      // Ephemeral IP - a new IP is assigned on each VM restart
      // For a static IP, create a google_compute_address resource
    }
  }

  # Startup script — feature-flagged, runs on first boot
  metadata_startup_script = <<-SCRIPT
    #!/bin/bash
    set -euo pipefail

    LOG_FILE="/var/log/obsidian-vm-setup.log"
    exec > >(tee -a "$LOG_FILE") 2>&1
    echo "=== Obsidian VM Setup Started at $(date) ==="

    # --------------------------------------------------------------------------
    # Feature flags (injected by Terraform)
    # --------------------------------------------------------------------------
    ENABLE_COUCHDB='${var.enable_couchdb}'
    ENABLE_HEADLESS_OBSIDIAN='${var.enable_headless_obsidian}'
    ENABLE_MCPVAULT='${var.enable_mcpvault}'
    ENABLE_CLAUDE_CLI='${var.enable_claude_cli}'
    ENABLE_RUNNER='${var.enable_runner}'
    VAULT_PATH='${var.obsidian_vault_path}'
    MCPVAULT_USER='${var.mcpvault_user}'
    MCPVAULT_PASSWORD='${var.mcpvault_password}'
    TAILSCALE_AUTH_KEY='${var.tailscale_auth_key}'
    ENABLE_HTTPS='${var.enable_https}'
    DUCKDNS_SUBDOMAIN='${var.duckdns_subdomain}'
    DUCKDNS_TOKEN='${var.duckdns_token}'

    # --------------------------------------------------------------------------
    # System update + base packages (always)
    # --------------------------------------------------------------------------
    echo ">>> Updating system packages..."
    apt-get update -y
    apt-get install -y ca-certificates curl gnupg lsb-release

    # --------------------------------------------------------------------------
    # Node.js 22 (needed for headless obsidian, mcpvault, or claude CLI)
    # --------------------------------------------------------------------------
    if [ "$ENABLE_HEADLESS_OBSIDIAN" = "true" ] || [ "$ENABLE_MCPVAULT" = "true" ] || [ "$ENABLE_CLAUDE_CLI" = "true" ]; then
      echo ">>> Installing Node.js 22..."
      curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
      apt-get install -y nodejs
      echo ">>> Node.js $(node --version) installed"
    fi

    # --------------------------------------------------------------------------
    # Docker + CouchDB (only when enable_couchdb = true)
    # --------------------------------------------------------------------------
    if [ "$ENABLE_COUCHDB" = "true" ]; then
      echo ">>> Installing Docker..."
      install -m 0755 -d /etc/apt/keyrings
      curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
      chmod a+r /etc/apt/keyrings/docker.gpg
      echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
        $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
      apt-get update -y
      apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
      systemctl enable docker
      systemctl start docker
      echo ">>> Docker installed"

      echo ">>> Starting CouchDB..."
      mkdir -p /opt/couchdb/data
      chmod 755 /opt/couchdb/data
      docker stop obsidian-couchdb 2>/dev/null || true
      docker rm obsidian-couchdb 2>/dev/null || true
      docker run -d \
        --name obsidian-couchdb \
        --restart unless-stopped \
        -p 5984:5984 \
        -e COUCHDB_USER='${var.couchdb_user}' \
        -e COUCHDB_PASSWORD='${var.couchdb_password}' \
        -v /opt/couchdb/data:/opt/couchdb/data \
        couchdb:latest
      echo ">>> CouchDB container started"

      echo ">>> Waiting for CouchDB to be ready..."
      MAX_ATTEMPTS=30
      ATTEMPT=0
      while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
        if curl -s http://localhost:5984/ | grep -q "couchdb"; then
          echo ">>> CouchDB is UP!"
          break
        fi
        ATTEMPT=$((ATTEMPT + 1))
        echo ">>> Waiting for CouchDB... ($ATTEMPT/$MAX_ATTEMPTS)"
        sleep 2
      done

      if [ $ATTEMPT -eq $MAX_ATTEMPTS ]; then
        echo ">>> WARNING: CouchDB health check timed out."
        docker logs obsidian-couchdb
      else
        echo ">>> Configuring CORS..."
        curl -X PUT http://'${var.couchdb_user}':'${var.couchdb_password}'@localhost:5984/_node/_local/_config/httpd/enable_cors \
          -d '"true"' -H "Content-Type: application/json"
        curl -X PUT http://'${var.couchdb_user}':'${var.couchdb_password}'@localhost:5984/_node/_local/_config/cors/origins \
          -d '"*"' -H "Content-Type: application/json"
        curl -X PUT http://'${var.couchdb_user}':'${var.couchdb_password}'@localhost:5984/_node/_local/_config/cors/credentials \
          -d '"true"' -H "Content-Type: application/json"
        curl -X PUT http://'${var.couchdb_user}':'${var.couchdb_password}'@localhost:5984/_node/_local/_config/cors/methods \
          -d '"GET, PUT, POST, HEAD, DELETE"' -H "Content-Type: application/json"
        curl -X PUT http://'${var.couchdb_user}':'${var.couchdb_password}'@localhost:5984/_node/_local/_config/cors/headers \
          -d '"accept, authorization, content-type, origin, referer, x-requested-with"' -H "Content-Type: application/json"
        echo ">>> CORS configured"
      fi
    fi

    # --------------------------------------------------------------------------
    # Obsidian Headless (continuous vault sync from Obsidian cloud)
    # --------------------------------------------------------------------------
    if [ "$ENABLE_HEADLESS_OBSIDIAN" = "true" ]; then
      echo ">>> Installing obsidian-headless..."
      npm install -g obsidian-headless
      mkdir -p "$VAULT_PATH"
      chmod 755 "$VAULT_PATH"

      cat > /etc/systemd/system/obsidian-sync.service <<OBSIDIAN_UNIT
[Unit]
Description=Obsidian Headless Continuous Sync
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/ob sync --continuous
WorkingDirectory=$VAULT_PATH
Restart=on-failure
RestartSec=30

[Install]
WantedBy=multi-user.target
OBSIDIAN_UNIT

      systemctl daemon-reload
      systemctl enable obsidian-sync
      # NOT started — requires manual: ob login → ob sync-setup → systemctl start obsidian-sync
      echo ">>> obsidian-sync service installed (not started — manual steps required)"
      echo ">>> SSH to VM, then: ob login && ob sync-list-remote && ob sync-setup --vault 'NAME'"
      echo ">>> Then: systemctl start obsidian-sync"
    fi

    # --------------------------------------------------------------------------
    # MCPVault + supergateway (MCP server over SSE on :3000)
    # --------------------------------------------------------------------------
    if [ "$ENABLE_MCPVAULT" = "true" ]; then
      echo ">>> Installing MCPVault + supergateway..."
      npm install -g @bitbonsai/mcpvault supergateway
      mkdir -p "$VAULT_PATH"
      chmod 755 "$VAULT_PATH"

      cat > /etc/systemd/system/mcpvault.service <<MCPVAULT_UNIT
[Unit]
Description=MCPVault MCP Server (SSE via supergateway)
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/npx supergateway --stdio "/usr/bin/npx @bitbonsai/mcpvault $VAULT_PATH" --port 3000
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
MCPVAULT_UNIT

      systemctl daemon-reload
      systemctl enable mcpvault
      systemctl start mcpvault
      echo ">>> MCPVault started on port 3000"
    fi

    # --------------------------------------------------------------------------
    # Claude CLI (for cron-based vault automation)
    # --------------------------------------------------------------------------
    if [ "$ENABLE_CLAUDE_CLI" = "true" ]; then
      echo ">>> Installing Claude CLI..."
      npm install -g @anthropic-ai/claude-code

      # Configure MCPVault as local stdio MCP server for cron jobs
      mkdir -p /root
      cat > /root/.claude.json <<CLAUDE_JSON
{
  "mcpServers": {
    "mcpvault": {
      "command": "npx",
      "args": ["@bitbonsai/mcpvault", "$VAULT_PATH"]
    }
  }
}
CLAUDE_JSON

      echo ">>> Claude CLI installed. MANUAL STEP: SSH to VM and run: claude login"
    fi

    # --------------------------------------------------------------------------
    # Obsidian Runner (Python scheduled prompt daemon)
    # --------------------------------------------------------------------------
    if [ "$ENABLE_RUNNER" = "true" ]; then
      echo ">>> Installing Obsidian Runner..."
      apt-get install -y python3-pip
      pip3 install pyyaml croniter python-frontmatter

      mkdir -p /opt/obsidian-runner

      cat > /opt/obsidian-runner/obsidian_runner.py <<'RUNNER_SCRIPT'
#!/usr/bin/env python3
"""Obsidian Scheduled Prompt Runner.

Reads schedules.yaml from the vault, fires LLM prompt jobs on cron schedules,
and writes results back into the vault as markdown. Hot-reloads config every 30s.
"""

import logging
import os
import time
from datetime import datetime

import frontmatter
import yaml
from croniter import croniter

VAULT_BASE = os.environ.get("VAULT_BASE", "/opt/obsidian-vault")
SCHEDULE_FILE = os.path.join(VAULT_BASE, "00-Inbox/_other/schedules.yaml")
LOG_FILE = os.path.join(VAULT_BASE, "00-Inbox/_other/schedules-log.md")
LOG_DIR = os.path.dirname(LOG_FILE)
CHECK_INTERVAL = 30

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger(__name__)


def load_schedule():
    try:
        with open(SCHEDULE_FILE) as f:
            data = yaml.safe_load(f)
        jobs = (data or {}).get("jobs", [])
        return [j for j in jobs if j.get("enabled", True)]
    except FileNotFoundError:
        logger.debug("Schedule file not found: %s", SCHEDULE_FILE)
        return []
    except Exception as e:
        logger.warning("Failed to load schedule: %s", e)
        return []


def jobs_due(jobs, since, now):
    due = []
    for job in jobs:
        try:
            cron = croniter(job["schedule"], since)
            next_fire = cron.get_next(datetime)
            if since < next_fire <= now:
                due.append(job)
        except Exception as e:
            logger.warning("Invalid schedule for job %s: %s", job.get("id"), e)
    return due


def call_llm(prompt_text, model="claude-sonnet-4-6", temperature=0.7):
    """Placeholder LLM call -- replace with real Anthropic API call."""
    logger.info(
        "  [LLM] model=%s temperature=%s prompt_len=%d", model, temperature, len(prompt_text)
    )
    return f"[placeholder response -- {datetime.now().isoformat()}]"


def execute_prompt(prompt_path):
    """Load a prompt file, call LLM, write output. Returns (success, status_msg)."""
    full_path = prompt_path if os.path.isabs(prompt_path) else os.path.join(VAULT_BASE, prompt_path)

    try:
        post = frontmatter.load(full_path)
    except FileNotFoundError:
        return False, "file not found"
    except Exception as e:
        return False, str(e)

    output_cfg = post.get("output", {})
    output_path = output_cfg.get("path", "") if isinstance(output_cfg, dict) else ""
    mode = post.get("mode", "append")
    model = post.get("model", "claude-sonnet-4-6")
    temperature = post.get("temperature", 0.7)

    if not output_path:
        logger.warning("  No output.path in frontmatter: %s", prompt_path)
        return False, "no output.path"

    result = call_llm(post.content, model=model, temperature=temperature)

    out_full = output_path if os.path.isabs(output_path) else os.path.join(VAULT_BASE, output_path)
    out_dir = os.path.dirname(out_full)
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)

    if mode == "append":
        separator = f"---\n*{datetime.now().strftime('%Y-%m-%d %H:%M')}*\n\n"
        with open(out_full, "a") as f:
            f.write(separator + result + "\n")
    else:
        with open(out_full, "w") as f:
            f.write(result + "\n")

    return True, "ok"


def execute_job(job):
    """Run all prompts in a job sequentially. Returns list of (prompt_path, success, msg)."""
    results = []
    for prompt_path in job.get("prompts", []):
        logger.info("  Running prompt: %s", prompt_path)
        success, msg = execute_prompt(prompt_path)
        results.append((prompt_path, success, msg))
        if success:
            logger.info("  OK %s", prompt_path)
        else:
            logger.warning("  FAIL %s (%s)", prompt_path, msg)
    return results


def write_log(job_id, results, run_time):
    """Append a markdown block to LOG_FILE."""
    os.makedirs(LOG_DIR, exist_ok=True)
    all_ok = all(s for _, s, _ in results)
    status = "OK" if all_ok else "FAIL"
    timestamp = run_time.strftime("%Y-%m-%d %H:%M")
    lines = [f"## {timestamp} -- {job_id} {status}"]
    for prompt_path, success, msg in results:
        mark = "OK" if success else f"FAIL ({msg})"
        lines.append(f"- `{prompt_path}` {mark}")
    lines.append("")
    block = "\n".join(lines) + "\n"
    try:
        with open(LOG_FILE, "a") as f:
            f.write(block)
    except Exception as e:
        logger.warning("Failed to write log: %s", e)


def main():
    logger.info("Obsidian Runner starting. VAULT_BASE=%s", VAULT_BASE)
    logger.info("Schedule file: %s", SCHEDULE_FILE)
    last_check = datetime.now()

    while True:
        time.sleep(CHECK_INTERVAL)
        now = datetime.now()
        jobs = load_schedule()
        due = jobs_due(jobs, last_check, now)
        for job in due:
            job_id = job.get("id", "unknown")
            logger.info("Running job: %s", job_id)
            results = execute_job(job)
            write_log(job_id, results, now)
        last_check = now


if __name__ == "__main__":
    main()
RUNNER_SCRIPT

      cat > /etc/systemd/system/obsidian-runner.service <<RUNNER_UNIT
[Unit]
Description=Obsidian Scheduled Prompt Runner
After=network.target obsidian-sync.service
Wants=obsidian-sync.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/obsidian-runner/obsidian_runner.py
Environment=VAULT_BASE=$VAULT_PATH
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
RUNNER_UNIT

      systemctl daemon-reload
      systemctl enable obsidian-runner
      systemctl start obsidian-runner
      echo ">>> Obsidian Runner started"
      echo ">>> Place schedules.yaml at: $VAULT_PATH/00-Inbox/_other/schedules.yaml"
      echo ">>> Execution log will appear at: $VAULT_PATH/00-Inbox/_other/schedules-log.md"
    fi

    # --------------------------------------------------------------------------
    # Tailscale (private SSH access — unchanged)
    # --------------------------------------------------------------------------
    if [ -n "$TAILSCALE_AUTH_KEY" ]; then
      echo ">>> Installing Tailscale..."
      curl -fsSL https://tailscale.com/install.sh | sh
      tailscale up --authkey="$TAILSCALE_AUTH_KEY" --accept-routes
      TAILSCALE_IP=$(tailscale ip -4)
      echo ">>> Tailscale connected! Private IP: $TAILSCALE_IP"
    else
      echo ">>> Tailscale not configured (skipping)"
    fi

    # --------------------------------------------------------------------------
    # DuckDNS + Caddy (HTTPS for public access)
    # --------------------------------------------------------------------------
    if [ "$ENABLE_HTTPS" = "true" ]; then
      echo ">>> Setting up HTTPS with DuckDNS + Caddy..."

      if [ -z "$DUCKDNS_SUBDOMAIN" ] || [ -z "$DUCKDNS_TOKEN" ]; then
        echo ">>> ERROR: HTTPS enabled but duckdns_subdomain or duckdns_token not set. Skipping."
      else
        EXTERNAL_IP=$(curl -s http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip -H 'Metadata-Flavor: Google')
        echo ">>> External IP: $EXTERNAL_IP"

        # DuckDNS auto-updater
        mkdir -p /opt/duckdns
        cat > /opt/duckdns/duck.sh <<DUCKDNS_SCRIPT
#!/bin/bash
echo url="https://www.duckdns.org/update?domains=$DUCKDNS_SUBDOMAIN&token=$DUCKDNS_TOKEN&ip=" | curl -k -o /opt/duckdns/duck.log -K -
DUCKDNS_SCRIPT
        chmod +x /opt/duckdns/duck.sh
        /opt/duckdns/duck.sh
        if grep -q "OK" /opt/duckdns/duck.log; then
          echo ">>> DuckDNS updated: $DUCKDNS_SUBDOMAIN.duckdns.org"
        else
          echo ">>> WARNING: DuckDNS update failed."
          cat /opt/duckdns/duck.log
        fi
        (crontab -l 2>/dev/null || true; echo "*/5 * * * * /opt/duckdns/duck.sh >/dev/null 2>&1") | crontab -

        # Install Caddy
        echo ">>> Installing Caddy..."
        apt-get install -y debian-keyring debian-archive-keyring apt-transport-https
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
        apt-get update -y
        apt-get install -y caddy
        echo ">>> Caddy installed"

        # Configure Caddy — routing depends on which services are enabled
        if [ "$ENABLE_MCPVAULT" = "true" ]; then
          # Generate bcrypt hash for MCPVault basic auth
          MCPVAULT_HASH=$(caddy hash-password --plaintext "$MCPVAULT_PASSWORD")

          if [ "$ENABLE_COUCHDB" = "true" ]; then
            # Both MCPVault (:3000) and CouchDB (:5984) — path-based routing
            cat > /etc/caddy/Caddyfile <<CADDYFILE
$DUCKDNS_SUBDOMAIN.duckdns.org {
    basicauth /mcp/* {
        $MCPVAULT_USER $MCPVAULT_HASH
    }
    handle /mcp/* {
        uri strip_prefix /mcp
        reverse_proxy localhost:3000
    }
    handle {
        reverse_proxy localhost:5984
    }
    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
    }
}
CADDYFILE
          else
            # MCPVault only — proxy everything with basic auth
            cat > /etc/caddy/Caddyfile <<CADDYFILE
$DUCKDNS_SUBDOMAIN.duckdns.org {
    basicauth /* {
        $MCPVAULT_USER $MCPVAULT_HASH
    }
    reverse_proxy localhost:3000
    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
    }
}
CADDYFILE
          fi
        else
          # CouchDB only — original config
          cat > /etc/caddy/Caddyfile <<CADDYFILE
$DUCKDNS_SUBDOMAIN.duckdns.org {
    reverse_proxy localhost:5984
    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        X-Frame-Options "DENY"
        X-Content-Type-Options "nosniff"
    }
}
CADDYFILE
        fi

        systemctl restart caddy
        systemctl enable caddy
        sleep 10

        if systemctl is-active --quiet caddy; then
          echo ">>> Caddy running! HTTPS URL: https://$DUCKDNS_SUBDOMAIN.duckdns.org"
          if [ "$ENABLE_MCPVAULT" = "true" ]; then
            echo ">>> MCPVault SSE endpoint: https://$DUCKDNS_SUBDOMAIN.duckdns.org/sse"
          fi
        else
          echo ">>> WARNING: Caddy failed to start."
          journalctl -u caddy -n 50 --no-pager
        fi
      fi
    else
      echo ">>> HTTPS not enabled (enable_https = false)"
    fi

    # --------------------------------------------------------------------------
    # Setup complete
    # --------------------------------------------------------------------------
    EXTERNAL_IP=$(curl -s http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip -H 'Metadata-Flavor: Google')
    echo "=== Setup Completed at $(date) ==="
    echo ">>> VM external IP: $EXTERNAL_IP"
    if [ "$ENABLE_COUCHDB" = "true" ]; then
      echo ">>> CouchDB: http://$EXTERNAL_IP:5984"
    fi
    if [ "$ENABLE_MCPVAULT" = "true" ] && [ "$ENABLE_HTTPS" = "true" ]; then
      echo ">>> MCPVault SSE: https://$DUCKDNS_SUBDOMAIN.duckdns.org/sse"
    fi
  SCRIPT

  # Service account for the VM (uses default compute service account)
  # For enhanced security, create a dedicated service account with minimal permissions
  service_account {
    scopes = ["cloud-platform"]
  }

  # Labels for organization and cost tracking
  labels = {
    purpose     = "obsidian-livesync"
    environment = "personal"
    managed_by  = "terraform"
  }

  # Allow stopping for update (required for some changes)
  allow_stopping_for_update = true
}
