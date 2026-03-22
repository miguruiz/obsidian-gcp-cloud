#!/bin/bash
# =============================================================================
# deploy.sh — Obsidian VM Service Orchestrator
# =============================================================================
# Idempotent. Runs on the VM via IAP SSH from CI/CD.
# Feature flags and config are passed as environment variables by the workflow.
#
# Usage: bash /tmp/services/deploy.sh
#
# Required env vars (passed by deploy-services.yml):
#   ENABLE_OBSIDIAN_SYNC, ENABLE_MCPVAULT, ENABLE_CLAUDE_CLI,
#   ENABLE_RUNNER, ENABLE_HTTPS, ENABLE_COUCHDB
#   VAULT_PATH, MCPVAULT_USER, MCPVAULT_PASSWORD,
#   DUCKDNS_SUBDOMAIN, DUCKDNS_TOKEN
# =============================================================================

set -euo pipefail

SERVICES_DIR="/tmp/services"
LOG_FILE="/var/log/obsidian-deploy.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=== Obsidian Deploy Started at $(date) ==="
echo ">>> Services dir: $SERVICES_DIR"

# Defaults
VAULT_PATH="${VAULT_PATH:-/opt/obsidian-vault}"
ENABLE_OBSIDIAN_SYNC="${ENABLE_OBSIDIAN_SYNC:-false}"
ENABLE_MCPVAULT="${ENABLE_MCPVAULT:-false}"
ENABLE_CLAUDE_CLI="${ENABLE_CLAUDE_CLI:-false}"
ENABLE_RUNNER="${ENABLE_RUNNER:-false}"
ENABLE_HTTPS="${ENABLE_HTTPS:-false}"
ENABLE_COUCHDB="${ENABLE_COUCHDB:-false}"

export VAULT_PATH ENABLE_OBSIDIAN_SYNC ENABLE_MCPVAULT ENABLE_CLAUDE_CLI \
       ENABLE_RUNNER ENABLE_HTTPS ENABLE_COUCHDB

# --------------------------------------------------------------------------
# Node.js — shared prerequisite for obsidian-sync, mcpvault, claude-cli
# --------------------------------------------------------------------------
NODE_MAJOR="22"

if [ "$ENABLE_OBSIDIAN_SYNC" = "true" ] || [ "$ENABLE_MCPVAULT" = "true" ] || [ "$ENABLE_CLAUDE_CLI" = "true" ]; then
  if node --version 2>/dev/null | grep -q "^v${NODE_MAJOR}\."; then
    echo ">>> Node.js v${NODE_MAJOR} already installed ($(node --version)), skipping"
  else
    echo ">>> Installing Node.js ${NODE_MAJOR}..."
    curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash -
    apt-get install -y nodejs
    echo ">>> Node.js $(node --version) installed"
  fi
fi

# --------------------------------------------------------------------------
# Services
# --------------------------------------------------------------------------

if [ "$ENABLE_COUCHDB" = "true" ]; then
  echo ">>> Deploying CouchDB..."
  bash "$SERVICES_DIR/couchdb/install.sh"
fi

if [ "$ENABLE_OBSIDIAN_SYNC" = "true" ]; then
  echo ">>> Deploying obsidian-sync..."
  bash "$SERVICES_DIR/obsidian-sync/install.sh"
fi

if [ "$ENABLE_MCPVAULT" = "true" ]; then
  echo ">>> Deploying MCPVault..."
  bash "$SERVICES_DIR/mcpvault/install.sh"
fi

if [ "$ENABLE_CLAUDE_CLI" = "true" ]; then
  echo ">>> Deploying Claude CLI..."
  bash "$SERVICES_DIR/claude-cli/install.sh"
fi

if [ "$ENABLE_RUNNER" = "true" ]; then
  echo ">>> Deploying obsidian-runner..."
  bash "$SERVICES_DIR/obsidian-runner/install.sh"
fi

if [ "$ENABLE_HTTPS" = "true" ]; then
  echo ">>> Deploying Caddy..."
  bash "$SERVICES_DIR/caddy/install.sh"
fi

echo "=== Deploy Completed at $(date) ==="
