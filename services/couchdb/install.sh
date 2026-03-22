#!/bin/bash
# =============================================================================
# couchdb/install.sh — Install CouchDB via Docker
# =============================================================================
# Idempotent. Called by deploy.sh when ENABLE_COUCHDB=true.
# Inherits env vars: COUCHDB_USER, COUCHDB_PASSWORD.
#
# NOTE: ENABLE_COUCHDB=false by default. This project uses Obsidian Sync.
# Only enable if switching back to self-hosted LiveSync.
# =============================================================================

set -euo pipefail

if [ -z "${COUCHDB_PASSWORD:-}" ]; then
  echo "  [couchdb] ERROR: COUCHDB_PASSWORD is required. Skipping."
  exit 1
fi

COUCHDB_USER="${COUCHDB_USER:-admin}"

# --------------------------------------------------------------------------
# Install Docker
# --------------------------------------------------------------------------
if ! command -v docker &>/dev/null; then
  echo "  [couchdb] Installing Docker..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
    $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  systemctl enable docker
  systemctl start docker
  echo "  [couchdb] Docker installed"
else
  echo "  [couchdb] Docker already installed"
fi

# --------------------------------------------------------------------------
# Run CouchDB container
# --------------------------------------------------------------------------
echo "  [couchdb] Starting CouchDB container..."
mkdir -p /opt/couchdb/data

docker stop obsidian-couchdb 2>/dev/null || true
docker rm obsidian-couchdb 2>/dev/null || true

docker run -d \
  --name obsidian-couchdb \
  --restart unless-stopped \
  -p 5984:5984 \
  -e COUCHDB_USER="$COUCHDB_USER" \
  -e COUCHDB_PASSWORD="$COUCHDB_PASSWORD" \
  -v /opt/couchdb/data:/opt/couchdb/data \
  couchdb:latest

echo "  [couchdb] Waiting for CouchDB to be ready..."
for i in $(seq 1 30); do
  if curl -s http://localhost:5984/ | grep -q "couchdb"; then
    echo "  [couchdb] CouchDB is UP!"
    break
  fi
  echo "  [couchdb] Waiting... ($i/30)"
  sleep 2
done

echo "  [couchdb] CouchDB running at http://localhost:5984"
