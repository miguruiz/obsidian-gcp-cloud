#!/bin/bash
# =============================================================================
# obsidian-runner/install.sh — Install Python scheduled prompt runner
# =============================================================================
# Idempotent. Called by deploy.sh when ENABLE_RUNNER=true.
# Inherits env vars from deploy.sh (VAULT_PATH).
# =============================================================================

set -euo pipefail

echo "  [obsidian-runner] Installing Python dependencies..."
pip3 install --break-system-packages -r /tmp/services/obsidian-runner/requirements.txt

echo "  [obsidian-runner] Copying runner script..."
mkdir -p /opt/obsidian-runner
cp /tmp/services/obsidian-runner/obsidian_runner.py /opt/obsidian-runner/obsidian_runner.py
chmod +x /opt/obsidian-runner/obsidian_runner.py

echo "  [obsidian-runner] Writing systemd unit..."
cp /tmp/services/obsidian-runner/obsidian-runner.service /etc/systemd/system/obsidian-runner.service

sed -i "s|__VAULT_PATH__|$VAULT_PATH|g" /etc/systemd/system/obsidian-runner.service

systemctl daemon-reload
systemctl enable obsidian-runner
systemctl restart obsidian-runner

echo "  [obsidian-runner] Runner started."
echo "  [obsidian-runner] Place schedules at: $VAULT_PATH/00-Inbox/_other/schedules.yaml"
