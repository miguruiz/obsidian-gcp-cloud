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
    # Optional: Install and Configure DuckDNS + Caddy (HTTPS)
    # --------------------------------------------------------------------------
    # Caddy provides automatic HTTPS with Let's Encrypt certificates
    # DuckDNS provides a free dynamic DNS subdomain
    ENABLE_HTTPS='${var.enable_https}'
    DUCKDNS_SUBDOMAIN='${var.duckdns_subdomain}'
    DUCKDNS_TOKEN='${var.duckdns_token}'

    if [ "$ENABLE_HTTPS" = "true" ]; then
      echo ">>> Setting up HTTPS with DuckDNS + Caddy..."

      # Validate required variables
      if [ -z "$DUCKDNS_SUBDOMAIN" ] || [ -z "$DUCKDNS_TOKEN" ]; then
        echo ">>> ERROR: HTTPS enabled but duckdns_subdomain or duckdns_token not set!"
        echo ">>> Skipping HTTPS setup. CouchDB will only be available via HTTP."
      else
        # Get external IP for DuckDNS
        EXTERNAL_IP=$(curl -s http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip -H 'Metadata-Flavor: Google')
        echo ">>> External IP: $EXTERNAL_IP"

        # --------------------
        # Set up DuckDNS
        # --------------------
        echo ">>> Configuring DuckDNS auto-updater..."

        mkdir -p /opt/duckdns

        # Create DuckDNS update script
        cat > /opt/duckdns/duck.sh <<DUCKDNS_SCRIPT
#!/bin/bash
echo url="https://www.duckdns.org/update?domains=$DUCKDNS_SUBDOMAIN&token=$DUCKDNS_TOKEN&ip=" | curl -k -o /opt/duckdns/duck.log -K -
DUCKDNS_SCRIPT

        chmod +x /opt/duckdns/duck.sh

        # Run initial update
        /opt/duckdns/duck.sh

        if grep -q "OK" /opt/duckdns/duck.log; then
          echo ">>> DuckDNS updated successfully!"
          echo ">>> Your domain: $DUCKDNS_SUBDOMAIN.duckdns.org"
        else
          echo ">>> WARNING: DuckDNS update failed. Check token and subdomain."
          cat /opt/duckdns/duck.log
        fi

        # Add to crontab (updates every 5 minutes)
        (crontab -l 2>/dev/null; echo "*/5 * * * * /opt/duckdns/duck.sh >/dev/null 2>&1") | crontab -
        echo ">>> DuckDNS auto-updater configured (runs every 5 min)"

        # --------------------
        # Install Caddy
        # --------------------
        echo ">>> Installing Caddy..."

        # Add Caddy repository
        apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list

        # Install Caddy
        apt-get update -y
        apt-get install -y caddy

        echo ">>> Caddy installed successfully"

        # --------------------
        # Configure Caddy
        # --------------------
        echo ">>> Configuring Caddy for HTTPS..."

        # Create Caddyfile
        cat > /etc/caddy/Caddyfile <<CADDYFILE
$DUCKDNS_SUBDOMAIN.duckdns.org {
    reverse_proxy localhost:5984

    # Optional: Add security headers
    header {
        # Enable HSTS
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        # Prevent clickjacking
        X-Frame-Options "DENY"
        # Prevent MIME sniffing
        X-Content-Type-Options "nosniff"
    }
}
CADDYFILE

        # Restart Caddy to apply configuration
        systemctl restart caddy
        systemctl enable caddy

        # Wait for Caddy to get certificate
        echo ">>> Waiting for Let's Encrypt certificate (may take 30-60 seconds)..."
        sleep 10

        # Check Caddy status
        if systemctl is-active --quiet caddy; then
          echo ">>> Caddy is running!"
          echo ">>> HTTPS URL: https://$DUCKDNS_SUBDOMAIN.duckdns.org"
          echo ">>> Testing HTTPS (may take a minute for DNS to propagate)..."
        else
          echo ">>> WARNING: Caddy failed to start. Check logs:"
          journalctl -u caddy -n 50 --no-pager
        fi
      fi
    else
      echo ">>> HTTPS not enabled (enable_https = false)"
      echo ">>> To add HTTPS later:"
      echo ">>>   1. Set enable_https = true in terraform.tfvars"
      echo ">>>   2. Set duckdns_subdomain and duckdns_token"
      echo ">>>   3. Redeploy with terraform apply"
    fi

    # --------------------------------------------------------------------------
    # Setup Complete
    # --------------------------------------------------------------------------
    echo "=== CouchDB Setup Completed at $(date) ==="

    # Get external IP
    EXTERNAL_IP=$(curl -s http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip -H 'Metadata-Flavor: Google')

    # Show access URLs
    echo ">>> CouchDB HTTP URL: http://$EXTERNAL_IP:5984"
    echo ">>> Admin UI (Fauxton): http://$EXTERNAL_IP:5984/_utils"

    if [ "$ENABLE_HTTPS" = "true" ] && [ -n "$DUCKDNS_SUBDOMAIN" ]; then
      echo ">>> CouchDB HTTPS URL: https://$DUCKDNS_SUBDOMAIN.duckdns.org"
      echo ">>> Use the HTTPS URL in Obsidian for mobile support!"
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

  # Ensure firewall rules exist before VM is created
  depends_on = [
    google_compute_firewall.allow_couchdb
  ]
}
