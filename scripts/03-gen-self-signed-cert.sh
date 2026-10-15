#!/usr/bin/env bash
# =============================================================================
# 03-gen-self-signed-cert.sh — TEMPORARY self-signed cert for the gateway.
# For production, replace nginx/certs/tls.crt + tls.key with a certificate
# issued by your internal CA (or Azure Key Vault), then:
#   docker compose exec gateway nginx -s reload
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
umask 077
source <(grep -E '^(GATEWAY_SERVER_NAME|GATEWAY_BIND_IP)=' .env)

mkdir -p nginx/certs
openssl req -x509 -nodes -newkey rsa:3072 -days 365 \
  -keyout nginx/certs/tls.key -out nginx/certs/tls.crt \
  -subj "/CN=${GATEWAY_SERVER_NAME}" \
  -addext "subjectAltName=DNS:${GATEWAY_SERVER_NAME},IP:${GATEWAY_BIND_IP},IP:127.0.0.1"
chmod 644 nginx/certs/tls.crt
chmod 600 nginx/certs/tls.key
echo "Self-signed certificate written to nginx/certs/ (CN=${GATEWAY_SERVER_NAME}, IP=${GATEWAY_BIND_IP})"
echo "Clients must trust nginx/certs/tls.crt, or use your internal CA certificate instead."
