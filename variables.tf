# =============================================================================
# variables.tf - Input variables for Obsidian LiveSync CouchDB deployment
# =============================================================================

# -----------------------------------------------------------------------------
# GCP Project Configuration
# -----------------------------------------------------------------------------

variable "project_id" {
  description = "The GCP project ID where resources will be created"
  type        = string

  validation {
    condition     = length(var.project_id) > 0
    error_message = "project_id is required and cannot be empty."
  }
}

variable "region" {
  description = "GCP region for resources. Use free-tier eligible regions (us-west1, us-central1, us-east1)"
  type        = string
  default     = "us-central1"

  validation {
    condition     = can(regex("^[a-z]+-[a-z]+[0-9]+$", var.region))
    error_message = "Region must be a valid GCP region (e.g., us-central1, us-west1)."
  }
}

variable "zone" {
  description = "GCP zone for the VM. Must be within the specified region and free-tier eligible"
  type        = string
  default     = "us-central1-a"

  validation {
    condition     = can(regex("^[a-z]+-[a-z]+[0-9]+-[a-z]$", var.zone))
    error_message = "Zone must be a valid GCP zone (e.g., us-central1-a, us-west1-b)."
  }
}

# -----------------------------------------------------------------------------
# CouchDB Configuration
# -----------------------------------------------------------------------------

variable "couchdb_user" {
  description = "Admin username for CouchDB"
  type        = string
  default     = "admin"

  validation {
    condition     = length(var.couchdb_user) >= 3
    error_message = "CouchDB username must be at least 3 characters."
  }
}

variable "couchdb_password" {
  description = "Admin password for CouchDB. REQUIRED - use a strong, unique password!"
  type        = string
  sensitive   = true # Prevents password from appearing in logs/output

  validation {
    condition     = length(var.couchdb_password) >= 12
    error_message = "CouchDB password must be at least 12 characters for security."
  }
}

# -----------------------------------------------------------------------------
# Network Security Configuration
# -----------------------------------------------------------------------------

variable "allowed_ips" {
  description = <<-EOT
    List of IP ranges allowed to access CouchDB (port 5984).

    SECURITY WARNING: The default ["0.0.0.0/0"] allows access from ANYWHERE!
    This is ONLY acceptable for initial testing.

    After deployment, IMMEDIATELY restrict this to your specific IP(s):
      - Your home IP: ["YOUR.HOME.IP.ADDRESS/32"]
      - Multiple IPs: ["IP1/32", "IP2/32"]
      - VPN range: ["10.0.0.0/8"]

    Better alternatives for production:
      - Use Tailscale (private network, no open ports)
      - Use Cloudflare Tunnel
      - Use a VPN
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "ssh_allowed_ips" {
  description = <<-EOT
    List of IP ranges allowed SSH access (port 22) to the VM.
    Leave empty [] to disable SSH firewall rule entirely.

    For security, only add your IP when you need to debug:
      - Your IP only: ["YOUR.IP.ADDRESS/32"]
      - Disable SSH: []

    You can also use GCP's Identity-Aware Proxy (IAP) for SSH instead.
  EOT
  type        = list(string)
  default     = [] # SSH disabled by default for security
}

# -----------------------------------------------------------------------------
# Optional: Tailscale Configuration
# -----------------------------------------------------------------------------

variable "tailscale_auth_key" {
  description = <<-EOT
    Tailscale authentication key for automatic network joining.

    Get this from: https://login.tailscale.com/admin/settings/keys
    - Create a new auth key
    - Mark as "Reusable"
    - Set appropriate expiration

    If provided, Tailscale will be installed and configured automatically.
    Leave empty to skip Tailscale installation.
  EOT
  type        = string
  default     = ""
  sensitive   = true # Auth keys are sensitive
}

# -----------------------------------------------------------------------------
# Optional: DuckDNS + Caddy Configuration (HTTPS)
# -----------------------------------------------------------------------------

variable "enable_https" {
  description = <<-EOT
    Enable HTTPS with DuckDNS + Caddy.

    If true, Caddy will be installed as a reverse proxy with automatic
    Let's Encrypt certificates. Requires duckdns_subdomain and duckdns_token.

    Set to false to use HTTP only (desktop only, no mobile support).
  EOT
  type        = bool
  default     = false
}

variable "duckdns_subdomain" {
  description = <<-EOT
    DuckDNS subdomain (e.g., "obsidian-yourname").

    Get a free subdomain from: https://www.duckdns.org/
    - Sign in with Google/GitHub
    - Create a subdomain
    - Your full domain will be: subdomain.duckdns.org

    Only used if enable_https = true.
  EOT
  type        = string
  default     = ""
}

variable "duckdns_token" {
  description = <<-EOT
    DuckDNS token for DNS updates.

    Get this from: https://www.duckdns.org/ (shown after login)

    Only used if enable_https = true.
    Security: Stored in Terraform state and VM metadata.
  EOT
  type        = string
  default     = ""
  sensitive   = true
}

# -----------------------------------------------------------------------------
# Optional: Terraform State Backend (for reference)
# -----------------------------------------------------------------------------
# These variables are used if you configure a GCS backend for state storage.
# The actual backend config goes in backend.tf or is passed via CLI.

variable "terraform_state_bucket" {
  description = "GCS bucket name for Terraform state storage (optional, for reference)"
  type        = string
  default     = ""
}
