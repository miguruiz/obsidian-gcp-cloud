# =============================================================================
# outputs.tf - Output values for Obsidian LiveSync CouchDB deployment
# =============================================================================

# -----------------------------------------------------------------------------
# VM Information
# -----------------------------------------------------------------------------

output "vm_name" {
  description = "Name of the CouchDB VM instance"
  value       = google_compute_instance.obsidian_couchdb_vm.name
}

output "vm_zone" {
  description = "Zone where the VM is deployed"
  value       = google_compute_instance.obsidian_couchdb_vm.zone
}

output "vm_external_ip" {
  description = "External IP address of the CouchDB VM"
  value       = google_compute_instance.obsidian_couchdb_vm.network_interface[0].access_config[0].nat_ip
}

output "vm_internal_ip" {
  description = "Internal IP address of the CouchDB VM (for VPC access)"
  value       = google_compute_instance.obsidian_couchdb_vm.network_interface[0].network_ip
}

# -----------------------------------------------------------------------------
# CouchDB Connection Details
# -----------------------------------------------------------------------------

output "couchdb_url" {
  description = "CouchDB HTTP URL for Obsidian LiveSync configuration"
  value       = "http://${google_compute_instance.obsidian_couchdb_vm.network_interface[0].access_config[0].nat_ip}:5984"
}

output "couchdb_admin_ui" {
  description = "CouchDB Fauxton admin UI URL"
  value       = "http://${google_compute_instance.obsidian_couchdb_vm.network_interface[0].access_config[0].nat_ip}:5984/_utils"
}

# -----------------------------------------------------------------------------
# SSH Access (for debugging)
# -----------------------------------------------------------------------------

output "ssh_command" {
  description = "SSH command to connect to the VM (requires SSH firewall rule)"
  value       = "gcloud compute ssh ${google_compute_instance.obsidian_couchdb_vm.name} --zone=${google_compute_instance.obsidian_couchdb_vm.zone} --project=${var.project_id}"
}

# -----------------------------------------------------------------------------
# Quick Setup Reminders
# -----------------------------------------------------------------------------

output "next_steps" {
  description = "Next steps after deployment"
  value       = <<-EOT

    ============================================================
    DEPLOYMENT SUCCESSFUL - Next Steps:
    ============================================================

    1. Wait 2-3 minutes for the startup script to complete

    2. Verify CouchDB is running:
       curl -u ${var.couchdb_user}:YOUR_PASSWORD ${google_compute_instance.obsidian_couchdb_vm.network_interface[0].access_config[0].nat_ip}:5984

    3. Configure Obsidian LiveSync:
       - Server URL: http://${google_compute_instance.obsidian_couchdb_vm.network_interface[0].access_config[0].nat_ip}:5984
       - Username: ${var.couchdb_user}
       - Password: (the password you configured)
       - Database: obsidian (or your preferred name)

    4. SECURITY - Restrict firewall access:
       - Update allowed_ips in terraform.tfvars to your IP only
       - Run: terraform apply

    5. RECOMMENDED - Install Tailscale for private access:
       ${google_compute_instance.obsidian_couchdb_vm.name}$ curl -fsSL https://tailscale.com/install.sh | sh
       ${google_compute_instance.obsidian_couchdb_vm.name}$ sudo tailscale up

    ============================================================
  EOT
}
