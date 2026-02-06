# =============================================================================
# backend.tf - Terraform State Backend Configuration
# =============================================================================
# This file configures remote state storage in Google Cloud Storage (GCS).

# MANUAL SETUP REQUIRED: You must create the GCS bucket before uncommenting
# the backend configuration. See README.md for instructions.
# =============================================================================

terraform {
  backend "gcs" {
    # Replace with your bucket name (must be globally unique)
    bucket = "obsidian-couchdb-tfstate-4235caa2"
    prefix = "terraform/state"

    # State locking is automatic with GCS backend
    # No additional configuration needed for locking
  }
}
# =============================================================================

# Why use remote state?
# ----------------------
# 1. CI/CD Compatibility: GitHub Actions needs access to state
# 2. Collaboration: Multiple machines can share state safely
# 3. State Locking: Prevents concurrent modifications
# 4. Security: Sensitive values stay out of git
# 5. Backup: GCS provides durability and versioning