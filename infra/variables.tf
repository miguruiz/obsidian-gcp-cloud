# =============================================================================
# variables.tf - Input variables for Obsidian VM infrastructure
# =============================================================================
# Only infrastructure-level variables live here.
# Service feature flags and config (vault path, passwords, etc.) are passed
# as env vars to services/deploy.sh by the deploy-services CI workflow.
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
# Network Security
# -----------------------------------------------------------------------------

variable "enable_https" {
  description = "Open port 443 firewall rule for Caddy HTTPS. Set true when MCPVault is enabled."
  type        = bool
  default     = false
}

# -----------------------------------------------------------------------------
# Optional: Terraform State Backend (for reference)
# -----------------------------------------------------------------------------

variable "terraform_state_bucket" {
  description = "GCS bucket name for Terraform state storage (optional, for reference)"
  type        = string
  default     = ""
}
