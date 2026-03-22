#!/bin/bash
# =============================================================================
# obsidian-sync/install.sh — Install obsidian-headless sync service
# =============================================================================
# Idempotent. Called by deploy.sh when ENABLE_OBSIDIAN_SYNC=true.
# Inherits env vars from deploy.sh (VAULT_PATH).
#
# NOTE: Service is enabled but NOT started. Manual steps required:
#   sudo -u obsidian ob login
#   sudo -u obsidian ob sync-setup --vault 'Your Vault Name'
#   systemctl start obsidian-sync
# =============================================================================

set -euo pipefail

if command -v ob &>/dev/null; then
  echo "  [obsidian-sync] obsidian-headless already installed ($(ob --version 2>/dev/null || echo 'unknown version')), skipping"
else
  echo "  [obsidian-sync] Installing obsidian-headless (large download, may take a few minutes)..."
  npm install -g obsidian-headless
fi

echo "  [obsidian-sync] Ensuring obsidian user and vault directory exist..."
useradd --system --create-home --shell /bin/bash obsidian 2>/dev/null || true
mkdir -p "$VAULT_PATH"
chown obsidian:obsidian "$VAULT_PATH"

echo "  [obsidian-sync] Writing systemd unit..."
cp /tmp/services/obsidian-sync/obsidian-sync.service /etc/systemd/system/obsidian-sync.service

# Inject vault path into unit
sed -i "s|__VAULT_PATH__|$VAULT_PATH|g" /etc/systemd/system/obsidian-sync.service

systemctl daemon-reload
systemctl enable obsidian-sync

echo "  [obsidian-sync] Installed. Service enabled but NOT started."
echo "  [obsidian-sync] Manual steps: sudo -u obsidian ob login && ob sync-setup --vault 'NAME'"
echo "  [obsidian-sync] Then: systemctl start obsidian-sync"
