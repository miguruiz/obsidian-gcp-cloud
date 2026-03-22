#!/bin/bash
# =============================================================================
# caddy/install.sh — Install Caddy HTTPS reverse proxy
# =============================================================================
# Idempotent. Called by deploy.sh when ENABLE_HTTPS=true.
# Inherits env vars from deploy.sh (MCPVAULT_USER, MCPVAULT_PASSWORD,
# DUCKDNS_SUBDOMAIN, DUCKDNS_TOKEN).
#
# Provides HTTPS termination + basic auth in front of MCPVault (:3000).
# Uses DuckDNS for dynamic DNS + Let's Encrypt for certificates.
# =============================================================================

set -euo pipefail

if [ -z "${DUCKDNS_SUBDOMAIN:-}" ] || [ -z "${DUCKDNS_TOKEN:-}" ]; then
  echo "  [caddy] ERROR: DUCKDNS_SUBDOMAIN and DUCKDNS_TOKEN are required. Skipping."
  exit 1
fi

# --------------------------------------------------------------------------
# DuckDNS auto-updater
# --------------------------------------------------------------------------
echo "  [caddy] Updating DuckDNS..."
mkdir -p /opt/duckdns
cat > /opt/duckdns/duck.sh <<'DUCKDNS'
#!/bin/bash
echo url="https://www.duckdns.org/update?domains=SUBDOMAIN&token=TOKEN&ip=" | curl -k -o /opt/duckdns/duck.log -K -
DUCKDNS

sed -i "s/SUBDOMAIN/$DUCKDNS_SUBDOMAIN/g; s/TOKEN/$DUCKDNS_TOKEN/g" /opt/duckdns/duck.sh
chmod +x /opt/duckdns/duck.sh
/opt/duckdns/duck.sh

if grep -q "OK" /opt/duckdns/duck.log; then
  echo "  [caddy] DuckDNS updated: $DUCKDNS_SUBDOMAIN.duckdns.org"
else
  echo "  [caddy] WARNING: DuckDNS update failed."
  cat /opt/duckdns/duck.log
fi

# Add cron if not already there
(crontab -l 2>/dev/null | grep -v duck.sh || true; echo "*/5 * * * * /opt/duckdns/duck.sh >/dev/null 2>&1") | crontab -

# --------------------------------------------------------------------------
# Install Caddy
# --------------------------------------------------------------------------
if ! command -v caddy &>/dev/null; then
  echo "  [caddy] Installing Caddy..."
  apt-get install -y debian-keyring debian-archive-keyring apt-transport-https
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -y
  apt-get install -y caddy
  echo "  [caddy] Caddy installed"
else
  echo "  [caddy] Caddy already installed ($(caddy version))"
fi

# --------------------------------------------------------------------------
# Write Caddyfile from template
# --------------------------------------------------------------------------
echo "  [caddy] Writing Caddyfile..."
MCPVAULT_HASH=$(caddy hash-password --plaintext "${MCPVAULT_PASSWORD}")

cp /tmp/services/caddy/Caddyfile.template /etc/caddy/Caddyfile
sed -i \
  -e "s|__DUCKDNS_SUBDOMAIN__|$DUCKDNS_SUBDOMAIN|g" \
  -e "s|__MCPVAULT_USER__|${MCPVAULT_USER:-admin}|g" \
  -e "s|__MCPVAULT_HASH__|$MCPVAULT_HASH|g" \
  /etc/caddy/Caddyfile

systemctl enable caddy
systemctl reload-or-restart caddy
sleep 5

if systemctl is-active --quiet caddy; then
  echo "  [caddy] Running. HTTPS: https://$DUCKDNS_SUBDOMAIN.duckdns.org"
  echo "  [caddy] MCPVault SSE: https://$DUCKDNS_SUBDOMAIN.duckdns.org/sse"
else
  echo "  [caddy] WARNING: Caddy failed to start."
  journalctl -u caddy -n 30 --no-pager
  exit 1
fi
