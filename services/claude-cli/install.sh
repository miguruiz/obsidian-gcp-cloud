#!/bin/bash
# =============================================================================
# claude-cli/install.sh — Install Claude CLI
# =============================================================================
# Idempotent. Called by deploy.sh when ENABLE_CLAUDE_CLI=true.
# Inherits env vars from deploy.sh (VAULT_PATH).
#
# NOTE: Requires manual login after first install:
#   claude login
# =============================================================================

set -euo pipefail

echo "  [claude-cli] Installing @anthropic-ai/claude-code..."
npm install -g @anthropic-ai/claude-code

echo "  [claude-cli] Writing Claude config with MCPVault as local stdio server..."
mkdir -p /root
cat > /root/.claude.json <<EOF
{
  "mcpServers": {
    "mcpvault": {
      "command": "npx",
      "args": ["@bitbonsai/mcpvault", "$VAULT_PATH"]
    }
  }
}
EOF

echo "  [claude-cli] Installed. MANUAL STEP: SSH to VM and run: claude login"
