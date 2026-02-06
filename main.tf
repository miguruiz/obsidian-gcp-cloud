# =============================================================================
# main.tf - Core infrastructure for Obsidian LiveSync CouchDB Backend
# =============================================================================
# This file defines the GCP resources needed to run a CouchDB instance on an
# e2-micro VM (free-tier eligible) for Obsidian Self-hosted LiveSync.
# =============================================================================

# -----------------------------------------------------------------------------
# Firewall Rules
# -----------------------------------------------------------------------------

# CouchDB access firewall rule
# WARNING: The default allows all IPs (0.0.0.0/0). This is INSECURE for production.
# After initial deployment, restrict allowed_ips to your specific IP addresses.
resource "google_compute_firewall" "allow_couchdb" {
  name    = "allow-couchdb-5984"
  network = "default"
  project = var.project_id

  description = "Allow CouchDB access on port 5984. RESTRICT allowed_ips after initial setup!"

  allow {
    protocol = "tcp"
    ports    = ["5984"]
  }

  # Source ranges - defaults to 0.0.0.0/0 but SHOULD be restricted
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

  # Startup script to install Docker and run CouchDB
  metadata_startup_script = <<-SCRIPT
    #!/bin/bash
    set -euo pipefail

    # ==========================================================================
    # Obsidian LiveSync CouchDB Setup Script
    # ==========================================================================

    LOG_FILE="/var/log/couchdb-setup.log"
    exec > >(tee -a "$LOG_FILE") 2>&1
    echo "=== CouchDB Setup Started at $(date) ==="

    # --------------------------------------------------------------------------
    # Install Docker
    # --------------------------------------------------------------------------
    echo ">>> Installing Docker..."

    # Update package index
    apt-get update -y

    # Install prerequisites
    apt-get install -y \
        ca-certificates \
        curl \
        gnupg \
        lsb-release

    # Add Docker's official GPG key
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    # Set up Docker repository
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
      $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

    # Install Docker Engine
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

    # Enable and start Docker
    systemctl enable docker
    systemctl start docker

    echo ">>> Docker installed successfully"

    # --------------------------------------------------------------------------
    # Create CouchDB data directory
    # --------------------------------------------------------------------------
    echo ">>> Creating CouchDB data directory..."
    mkdir -p /opt/couchdb/data
    chmod 755 /opt/couchdb/data

    # --------------------------------------------------------------------------
    # Run CouchDB Container
    # --------------------------------------------------------------------------
    echo ">>> Starting CouchDB container..."

    # Stop and remove existing container if present (for idempotency)
    docker stop obsidian-couchdb 2>/dev/null || true
    docker rm obsidian-couchdb 2>/dev/null || true

    # Run CouchDB with credentials from Terraform variables
    docker run -d \
      --name obsidian-couchdb \
      --restart unless-stopped \
      -p 5984:5984 \
      -e COUCHDB_USER='${var.couchdb_user}' \
      -e COUCHDB_PASSWORD='${var.couchdb_password}' \
      -v /opt/couchdb/data:/opt/couchdb/data \
      couchdb:latest

    echo ">>> CouchDB container started"

    # --------------------------------------------------------------------------
    # Health Check
    # --------------------------------------------------------------------------
    echo ">>> Waiting for CouchDB to be ready..."

    MAX_ATTEMPTS=30
    ATTEMPT=0

    while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
      if curl -s http://localhost:5984/ | grep -q "couchdb"; then
        echo ">>> CouchDB is UP and responding!"
        curl -s http://localhost:5984/ | head -5
        break
      fi
      ATTEMPT=$((ATTEMPT + 1))
      echo ">>> Waiting for CouchDB... (attempt $ATTEMPT/$MAX_ATTEMPTS)"
      sleep 2
    done

    if [ $ATTEMPT -eq $MAX_ATTEMPTS ]; then
      echo ">>> WARNING: CouchDB health check timed out. Check container logs:"
      docker logs obsidian-couchdb
    fi

    # --------------------------------------------------------------------------
    # Optional: Install and Configure Tailscale
    # --------------------------------------------------------------------------
    # Tailscale provides private network access without exposing ports publicly
    TAILSCALE_AUTH_KEY='${var.tailscale_auth_key}'

    if [ -n "$TAILSCALE_AUTH_KEY" ]; then
      echo ">>> Installing Tailscale..."

      # Install Tailscale using official installer
      curl -fsSL https://tailscale.com/install.sh | sh

      # Start Tailscale with auth key (non-interactive)
      echo ">>> Connecting to Tailscale network..."
      tailscale up --authkey="$TAILSCALE_AUTH_KEY" --accept-routes

      # Get Tailscale IP
      TAILSCALE_IP=$(tailscale ip -4)
      echo ">>> Tailscale connected! Private IP: $TAILSCALE_IP"
      echo ">>> Access CouchDB privately at: http://$TAILSCALE_IP:5984"

      # Optionally advertise this as an exit node (uncomment if needed)
      # tailscale up --authkey="$TAILSCALE_AUTH_KEY" --advertise-exit-node
    else
      echo ">>> Tailscale auth key not provided, skipping Tailscale installation"
      echo ">>> To add Tailscale later, SSH to the VM and run:"
      echo ">>>   curl -fsSL https://tailscale.com/install.sh | sh"
      echo ">>>   sudo tailscale up"
    fi

    # --------------------------------------------------------------------------
    # Setup Complete
    # --------------------------------------------------------------------------
    echo "=== CouchDB Setup Completed at $(date) ==="
    echo ">>> CouchDB URL: http://$(curl -s http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip -H 'Metadata-Flavor: Google'):5984"
    echo ">>> Admin UI (Fauxton): http://$(curl -s http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip -H 'Metadata-Flavor: Google'):5984/_utils"
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

  # Ensure firewall rules exist before VM is created
  depends_on = [
    google_compute_firewall.allow_couchdb
  ]
}
