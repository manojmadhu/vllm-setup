#!/usr/bin/env bash
# =============================================================================
# smoke-test.sh — verify security controls and inference through the gateway.
# Usage:  bash scripts/smoke-test.sh <client-api-key> [gateway-url]
# Default URL is https://<GATEWAY_BIND_IP> from .env
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."
source <(grep -E '^(GATEWAY_BIND_IP|SERVED_MODEL_NAME)=' .env)
KEY=${1:?usage: smoke-test.sh <client-api-key> [url]}
URL=${2:-https://${GATEWAY_BIND_IP}}
CA=(--cacert nginx/certs/tls.crt)
[[ "$URL" == *"${GATEWAY_BIND_IP}"* ]] || CA=()
pass=0; fail=0
check() { if [[ "$2" == "$3" ]]; then echo "PASS  $1 ($2)"; ((pass++)); else echo "FAIL  $1 (got $2, want $3)"; ((fail++)); fi; }
code() { curl -s -o /dev/null -w '%{http_code}' "${CA[@]}" --max-time 120 "$@"; }

echo "Gateway: $URL"
check "vLLM port 8000 not reachable from host" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:8000/health || true)" "000"
check "health endpoint"                 "$(code "$URL/health")" "200"
check "no key -> 401"                   "$(code "$URL/v1/models")" "401"
check "wrong key -> 401"                "$(code -H 'Authorization: Bearer nope' "$URL/v1/models")" "401"
check "metrics hidden -> 404"           "$(code -H "Authorization: Bearer $KEY" "$URL/metrics")" "404"
check "tokenize hidden -> 404"          "$(code -H "Authorization: Bearer $KEY" "$URL/tokenize")" "404"
check "list models with key -> 200"     "$(code -H "Authorization: Bearer $KEY" "$URL/v1/models")" "200"

echo; echo "Chat completion:"
start=$(date +%s.%N)
resp=$(curl -s "${CA[@]}" --max-time 300 "$URL/v1/chat/completions" \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d "{\"model\":\"${SERVED_MODEL_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"In one sentence, what is retrieval-augmented generation?\"}],\"max_tokens\":120,\"temperature\":0.2}")
end=$(date +%s.%N)
echo "$resp" | jq -r '.choices[0].message.content // .' 2>/dev/null || echo "$resp"
toks=$(echo "$resp" | jq -r '.usage.completion_tokens // 0' 2>/dev/null)
secs=$(echo "$end - $start" | bc)
[[ "$toks" -gt 0 ]] && { echo "  ${toks} tokens in ${secs}s (~$(echo "scale=1; $toks / $secs" | bc) tok/s incl. prefill)"; ((pass++)); } || { echo "FAIL  completion"; ((fail++)); }

echo; echo "Rate limit probe (30 rapid /v1/models calls):"
codes=$(for i in $(seq 30); do code -H "Authorization: Bearer $KEY" "$URL/v1/models"; echo; done | sort | uniq -c)
echo "$codes"
echo "$codes" | grep -q ' 429' && { echo "PASS  rate limiting active"; ((pass++)); } || echo "INFO  no 429 seen (burst allowance not exceeded)"

echo; echo "Result: ${pass} passed, ${fail} failed"
[[ $fail -eq 0 ]]
