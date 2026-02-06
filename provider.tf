# =============================================================================
# provider.tf - Terraform and Provider configuration
# =============================================================================

# -----------------------------------------------------------------------------
# Terraform Configuration
# -----------------------------------------------------------------------------

terraform {
  # Require Terraform 1.5+ for latest features and stability
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0" # Use latest 5.x for GCP features
    }
  }

  # Backend configuration is in backend.tf
}

# -----------------------------------------------------------------------------
# Google Cloud Provider
# -----------------------------------------------------------------------------

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone

  # Authentication is handled automatically by:
  # - Local: gcloud auth application-default login
  # - CI/CD: Workload Identity Federation (OIDC token from GitHub Actions)

  # Default labels applied to all resources (optional)
  default_labels = {
    managed_by = "terraform"
    project    = "obsidian-livesync"
  }
}

# -----------------------------------------------------------------------------
# Data Sources (for reference/validation)
# -----------------------------------------------------------------------------

# Verify the project exists and is accessible
data "google_project" "current" {
  project_id = var.project_id
}

# Get available zones in the region (for validation/reference)
data "google_compute_zones" "available" {
  project = var.project_id
  region  = var.region
}
