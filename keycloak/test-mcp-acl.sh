#!/usr/bin/env bash
# Exercises the pyats-tools MCP ACLs through Kong as each demo user:
#   1. no token                       -> 401
#   2. tools/list per user            -> only the tools that user may see
#   3. raw tools/call of a config tool -> 403 for the viewer, allowed for admin
# The tools/call sends an empty config, so even the admin call doesn't change
# anything on the device.
#
# Usage: ./keycloak/test-mcp-acl.sh
set -euo pipefail

KEYCLOAK_URL="${KEYCLOAK_URL:-http://localhost:8080}"
MCP_URL="${MCP_URL:-http://localhost:8010/pyats-tools}"

token() {
  curl -s "$KEYCLOAK_URL/realms/kong/protocol/openid-connect/token" \
    -d client_id=mcp-client -d grant_type=password \
    -d username="$1" -d password=kong | jq -r .access_token
}

# mcp <token> <session-id> <json-rpc body> -> prints "HTTP_CODE<TAB>SESSION<TAB>BODY"
mcp() {
  local hdrs body
  hdrs=$(mktemp)
  body=$(curl -s -D "$hdrs" -X POST "$MCP_URL" \
    -H "Authorization: Bearer $1" \
    ${2:+-H "Mcp-Session-Id: $2"} \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -d "$3")
  local code session
  code=$(head -1 "$hdrs" | awk '{print $2}')
  session=$(grep -i '^mcp-session-id:' "$hdrs" | awk '{print $2}' | tr -d '\r' || true)
  rm -f "$hdrs"
  # Streamable HTTP answers as SSE; keep only the JSON payload.
  printf '%s\t%s\t%s\n' "$code" "$session" "$(sed -n 's/^data: //p' <<<"$body" | tail -1)"
}

open_session() {
  local out session
  out=$(mcp "$1" "" '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"acl-test","version":"0"}}}')
  session=$(cut -f2 <<<"$out")
  mcp "$1" "$session" '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null
  echo "$session"
}

echo "== No token"
curl -s -o /dev/null -w "initialize -> HTTP %{http_code}\n" -X POST "$MCP_URL" \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -d '{}'

for user in netops-viewer-user netops-admin-user; do
  echo
  echo "== $user"
  t=$(token "$user")
  s=$(open_session "$t")

  out=$(mcp "$t" "$s" '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')
  echo "tools/list -> HTTP $(cut -f1 <<<"$out")"
  cut -f3- <<<"$out" | jq -r '.result.tools[].name' | sort | sed 's/^/  - /'

  out=$(mcp "$t" "$s" '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"pyats_configure_device","arguments":{"device_name":"R1","config_commands":""}}}')
  echo "tools/call pyats_configure_device -> HTTP $(cut -f1 <<<"$out")"
done
