# =============================================================================
# main.tf - Core infrastructure for Obsidian Cloud VM
# =============================================================================
# GCP e2-micro VM (free-tier eligible) running modular services.
# Services are installed/updated by services/deploy.sh via CI/CD (not here).
# Startup script = bootstrap only: runs once on first VM boot.
# =============================================================================

# -----------------------------------------------------------------------------
# Firewall Rules
# -----------------------------------------------------------------------------

# Allow SSH from GCP IAP only (35.235.240.0/20) — enables gcloud compute ssh --tunnel-through-iap
resource "google_compute_firewall" "allow_ssh_iap" {
  name     = "allow-ssh-iap"
  network  = "default"
  project  = var.project_id
  priority = 999

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["35.235.240.0/20"]
}

# Deny public SSH and RDP — overrides GCP's default allow rules (priority 65534)
resource "google_compute_firewall" "deny_ssh_public" {
  name     = "deny-ssh-public"
  network  = "default"
  project  = var.project_id
  priority = 1000

  deny {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"]
}

resource "google_compute_firewall" "deny_rdp_public" {
  name     = "deny-rdp-public"
  network  = "default"
  project  = var.project_id
  priority = 1000

  deny {
    protocol = "tcp"
    ports    = ["3389"]
  }

  source_ranges = ["0.0.0.0/0"]
}

# HTTPS access firewall rule (for Caddy reverse proxy)
resource "google_compute_firewall" "allow_https" {
  count   = var.enable_https ? 1 : 0
  name    = "allow-https-vm"
  network = "default"
  project = var.project_id

  description = "Allow HTTPS access for Caddy reverse proxy"

  allow {
    protocol = "tcp"
    ports    = ["443"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["obsidian-vm"]
}

# -----------------------------------------------------------------------------
# Compute Instance
# -----------------------------------------------------------------------------

resource "google_compute_instance" "obsidian_vm" {
  name         = "obsidian-vm"
  machine_type = "e2-micro" # Free-tier eligible
  zone         = var.zone
  project      = var.project_id

  tags = ["obsidian-vm"]

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
      size  = 30        # GB — free tier allows up to 30GB pd-standard
      type  = "pd-standard"
    }
    auto_delete = true
  }

  network_interface {
    network = "default"

    access_config {
      // Ephemeral external IP
    }
  }

  # Bootstrap only — runs once on first VM boot.
  # All service installation is handled by services/deploy.sh via CI/CD.
  metadata_startup_script = <<-SCRIPT
    #!/bin/bash
    set -euo pipefail

    LOG_FILE="/var/log/obsidian-vm-setup.log"
    exec > >(tee -a "$LOG_FILE") 2>&1
    echo "=== Obsidian VM Bootstrap Started at $(date) ==="

    # --------------------------------------------------------------------------
    # System update + base packages
    # --------------------------------------------------------------------------
    echo ">>> Updating system packages..."
    apt-get update -y
    apt-get install -y ca-certificates curl gnupg lsb-release python3-pip

    # --------------------------------------------------------------------------
    # Create obsidian system user + directories
    # --------------------------------------------------------------------------
    echo ">>> Creating obsidian system user..."
    useradd --system --create-home --shell /bin/bash obsidian 2>/dev/null || true

    echo ">>> Creating vault and runner directories..."
    mkdir -p /opt/obsidian-vault /opt/obsidian-runner
    chown obsidian:obsidian /opt/obsidian-vault
    chmod 755 /opt/obsidian-vault /opt/obsidian-runner

    # --------------------------------------------------------------------------
    # Tailscale (early — ensures SSH access even if later steps fail)
    # --------------------------------------------------------------------------
    TAILSCALE_AUTH_KEY='${var.tailscale_auth_key}'
    if [ -n "$TAILSCALE_AUTH_KEY" ]; then
      echo ">>> Installing Tailscale..."
      curl -fsSL https://tailscale.com/install.sh | sh
      tailscale up --authkey="$TAILSCALE_AUTH_KEY" --accept-routes --accept-dns=false
      echo ">>> Tailscale connected: $(tailscale ip -4)"
    else
      echo ">>> Tailscale not configured (skipping)"
    fi

    echo "=== Bootstrap Completed at $(date) ==="
    echo ">>> Services will be deployed by CI/CD via services/deploy.sh"
  SCRIPT

  service_account {
    scopes = ["cloud-platform"]
  }

  labels = {
    purpose     = "obsidian"
    environment = "personal"
    managed_by  = "terraform"
  }

  allow_stopping_for_update = true
}
