#!/bin/bash
# =============================================================================
# mcpvault/install.sh — Install MCPVault MCP server via supergateway
# =============================================================================
# Idempotent. Called by deploy.sh when ENABLE_MCPVAULT=true.
# Inherits env vars from deploy.sh (VAULT_PATH).
#
# Exposes vault as an MCP server over SSE on port 3000.
# Caddy (enable_https) provides HTTPS + basic auth on top.
# =============================================================================

set -euo pipefail

echo "  [mcpvault] Installing @bitbonsai/mcpvault and supergateway..."
npm install -g @bitbonsai/mcpvault supergateway

echo "  [mcpvault] Ensuring vault directory exists..."
mkdir -p "$VAULT_PATH"
chmod 755 "$VAULT_PATH"

echo "  [mcpvault] Writing systemd unit..."
cp /tmp/services/mcpvault/mcpvault.service /etc/systemd/system/mcpvault.service

sed -i "s|__VAULT_PATH__|$VAULT_PATH|g" /etc/systemd/system/mcpvault.service

systemctl daemon-reload
systemctl enable mcpvault
systemctl restart mcpvault

echo "  [mcpvault] MCPVault running on port 3000."
