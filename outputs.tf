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

output "couchdb_https_url" {
  description = "CouchDB HTTPS URL (if HTTPS is enabled)"
  value       = var.enable_https && var.duckdns_subdomain != "" ? "https://${var.duckdns_subdomain}.duckdns.org" : "HTTPS not enabled"
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

output "mcpvault_url" {
  description = "MCPVault SSE endpoint URL for Claude.ai integration"
  value       = var.enable_mcpvault && var.enable_https && var.duckdns_subdomain != "" ? "https://${var.duckdns_subdomain}.duckdns.org/sse" : "Enable enable_mcpvault + enable_https to get HTTPS URL"
}

output "obsidian_headless_next_steps" {
  description = "Manual steps required to activate Obsidian Sync on the VM"
  value = var.enable_headless_obsidian ? join("\n", [
    "SSH: gcloud compute ssh obsidian-couchdb-vm --zone=${var.zone}",
    "Then: ob login",
    "Then: ob sync-list-remote",
    "Then: ob sync-setup --vault 'Your Vault Name'",
    "Then: systemctl start obsidian-sync",
    "Check: journalctl -u obsidian-sync -f"
  ]) : "Headless Obsidian not enabled (enable_headless_obsidian = false)"
}

output "next_steps" {
  description = "Next steps after deployment"
  value       = <<-EOT

    ============================================================
    DEPLOYMENT SUCCESSFUL - Next Steps:
    ============================================================

    1. Wait 2-3 minutes for the startup script to complete

    %{if var.enable_couchdb}2. Verify CouchDB is running:
       curl -u ${var.couchdb_user}:YOUR_PASSWORD ${google_compute_instance.obsidian_couchdb_vm.network_interface[0].access_config[0].nat_ip}:5984

    3. Configure Obsidian LiveSync:
       - Server URL: http://${google_compute_instance.obsidian_couchdb_vm.network_interface[0].access_config[0].nat_ip}:5984
       - Username: ${var.couchdb_user}
       - Database: obsidian (or your preferred name)

    %{endif}%{if var.enable_headless_obsidian}Obsidian Headless - Manual steps required:
       1. SSH: gcloud compute ssh obsidian-couchdb-vm --zone=${var.zone}
       2. ob login
       3. ob sync-list-remote
       4. ob sync-setup --vault 'Your Vault Name'
       5. systemctl start obsidian-sync
       6. journalctl -u obsidian-sync -f

    %{endif}%{if var.enable_claude_cli}Claude CLI - Manual step required:
       SSH to VM then run: claude login

    %{endif}%{if var.enable_mcpvault && var.enable_https}MCPVault HTTPS endpoint:
       https://${var.duckdns_subdomain}.duckdns.org/sse
       Add to Claude.ai: Integrations -> Add MCP server

    %{endif}============================================================
  EOT
}
