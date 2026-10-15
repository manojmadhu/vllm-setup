#!/usr/bin/env bash
# =============================================================================
# manage-keys.sh — per-application API keys for the gateway
#
#   bash scripts/manage-keys.sh add    <client-name>   # prints the new key ONCE
#   bash scripts/manage-keys.sh revoke <client-name>
#   bash scripts/manage-keys.sh list
#
# Each client (RAG service, agent, team) gets its own key, its own rate-limit
# bucket and its own name in the access logs. Changes apply with a graceful
# nginx reload — no dropped connections.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
MAP=nginx/api-keys/keys.map
mkdir -p "$(dirname "$MAP")"; touch "$MAP"

reload() {
  [[ "${NO_RELOAD:-0}" == "1" ]] && return 0
  if docker compose ps --status running gateway 2>/dev/null | grep -q gateway; then
    docker compose exec -T gateway nginx -t && docker compose exec -T gateway nginx -s reload
    echo "Gateway reloaded."
  fi
}

cmd=${1:-}; name=${2:-}
[[ "${3:-}" == "--no-reload" ]] && NO_RELOAD=1

case "$cmd" in
  add)
    [[ "$name" =~ ^[a-z0-9][a-z0-9_-]{1,40}$ ]] || { echo "Client name: lowercase letters, digits, - or _"; exit 1; }
    if grep -qE "[[:space:]]${name};$" "$MAP"; then echo "Client '${name}' already exists"; exit 1; fi
    key="sk-llm-$(openssl rand -hex 24)"
    printf '"Bearer %s"  %s;\n' "$key" "$name" >> "$MAP"
    echo "Created key for '${name}' (store it in your secret manager; it is not shown again):"
    echo
    echo "  ${key}"
    echo
    reload
    ;;
  revoke)
    grep -qE "[[:space:]]${name};$" "$MAP" || { echo "No client '${name}'"; exit 1; }
    sed -i "/[[:space:]]${name};$/d" "$MAP"
    echo "Revoked '${name}'."
    reload
    ;;
  list)
    grep -vE '^\s*#' "$MAP" | awk '{print $NF}' | tr -d ';' | sed '/^$/d'
    ;;
  *)
    sed -n '3,9p' "$0"; exit 1 ;;
esac
