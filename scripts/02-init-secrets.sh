#!/usr/bin/env bash
# =============================================================================
# 02-init-secrets.sh — create .env, generate secrets, create the first client
# API key and a TLS certificate if none exists. Safe to re-run: existing
# values are never overwritten.
# Usage:  bash scripts/02-init-secrets.sh
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
umask 077

rand() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c "${1:-40}"; }

if [[ ! -f .env ]]; then
  cp .env.example .env
  echo "Created .env from .env.example"
fi
chmod 600 .env

set_if_empty() {           # set_if_empty KEY VALUE
  local key=$1 val=$2
  if grep -qE "^${key}=$" .env; then
    sed -i "s|^${key}=$|${key}=${val}|" .env
    echo "Generated ${key}"
  fi
}
set_if_empty VLLM_API_KEY "vllm-internal-$(rand 48)"
set_if_empty GRAFANA_ADMIN_PASSWORD "$(rand 24)"

# Detect the private IP of the primary NIC and offer it as the bind address
PRIV_IP=$(command -v ip >/dev/null && ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -1 || true)
if grep -q '^GATEWAY_BIND_IP=10.0.0.4$' .env && [[ -n "${PRIV_IP}" ]]; then
  sed -i "s|^GATEWAY_BIND_IP=.*|GATEWAY_BIND_IP=${PRIV_IP}|" .env
  echo "Set GATEWAY_BIND_IP=${PRIV_IP} (VM private IP) — verify this is correct"
fi

# First client key
mkdir -p nginx/api-keys
if [[ ! -s nginx/api-keys/keys.map ]]; then
  echo "# \"Bearer <key>\"  <client-name>;   — managed by scripts/manage-keys.sh" > nginx/api-keys/keys.map
  bash scripts/manage-keys.sh add admin-test --no-reload
fi
chmod 600 nginx/api-keys/keys.map   # container root reads it; keep it private on the host

# TLS certificate (self-signed placeholder if none present)
if [[ ! -f nginx/certs/tls.crt ]]; then
  bash scripts/03-gen-self-signed-cert.sh
fi

echo
echo "Secrets ready. Review .env (MODEL_ID, GATEWAY_SERVER_NAME, rate limits),"
echo "then run:  bash scripts/04-download-model.sh"
