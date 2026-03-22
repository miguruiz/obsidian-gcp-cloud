# =============================================================================
# outputs.tf - Output values for Obsidian VM deployment
# =============================================================================

output "vm_name" {
  description = "Name of the VM instance"
  value       = google_compute_instance.obsidian_vm.name
}

output "vm_zone" {
  description = "Zone where the VM is deployed"
  value       = google_compute_instance.obsidian_vm.zone
}

output "vm_external_ip" {
  description = "External IP address of the VM"
  value       = google_compute_instance.obsidian_vm.network_interface[0].access_config[0].nat_ip
}

output "vm_internal_ip" {
  description = "Internal IP address of the VM"
  value       = google_compute_instance.obsidian_vm.network_interface[0].network_ip
}

output "ssh_command" {
  description = "IAP SSH command to connect to the VM"
  value       = "gcloud compute ssh ${google_compute_instance.obsidian_vm.name} --zone=${google_compute_instance.obsidian_vm.zone} --project=${var.project_id} --tunnel-through-iap"
}

output "next_steps" {
  description = "Next steps after infrastructure deployment"
  value       = <<-EOT

    ============================================================
    INFRASTRUCTURE DEPLOYED — Next Steps:
    ============================================================

    1. Wait ~2 minutes for the bootstrap script to complete.

    2. Services are deployed automatically by the deploy-services
       CI workflow (triggered after this apply).

    3. One-time manual steps after first VM creation:
       - SSH: gcloud compute ssh obsidian-vm --zone=${var.zone} --tunnel-through-iap
       - sudo -u obsidian ob login
       - sudo -u obsidian ob sync-setup --vault 'Your Vault Name'
       - systemctl start obsidian-sync
       - claude login

    SSH: gcloud compute ssh ${google_compute_instance.obsidian_vm.name} --zone=${google_compute_instance.obsidian_vm.zone} --project=${var.project_id} --tunnel-through-iap
    ============================================================
  EOT
}
