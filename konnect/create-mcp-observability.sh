#!/usr/bin/env bash
# Sends a log record for every request on the pyats-tools MCP server to the
# observability stack (docker compose --profile observability):
#   - "mcp-http-log" AI Gateway policy (http-log): Kong POSTs each request's
#     log record - consumer, authenticated user, MCP method/tool, and the
#     request/response payloads (the server has logging.payloads on) - to
#     Vector, which forwards it to Loki for Grafana.
#   - attaches the policy to the MCP server (its "policies" list).
# Safe to re-run: the policy is updated in place and attached only once.
#
# Usage: ./konnect/create-mcp-observability.sh   (reads PAT and AI_GATEWAY_ID from .env)
#        ./konnect/create-mcp-observability.sh remove   (detach and delete the policy)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
set -a; . "$ROOT_DIR/.env"; set +a

: "${PAT:?Set PAT in .env}"
: "${AI_GATEWAY_ID:?Set AI_GATEWAY_ID in .env}"
: "${KONNECT_REGION:=eu}"
: "${MCP_SERVER_NAME:=pyats-tools}"
: "${MCP_LOG_ENDPOINT:=http://vector:9880/kong}"
POLICY_NAME=mcp-http-log

API="https://${KONNECT_REGION}.api.konghq.com/v1/ai-gateways/$AI_GATEWAY_ID"
auth=(-H "Authorization: Bearer $PAT" -H "Content-Type: application/json")

find_by_name() {
  curl -s "$API/$1" "${auth[@]}" | jq -r --arg n "$2" '.data[] | select(.name == $n) | .id'
}

MCP_ID=$(find_by_name mcp-servers "$MCP_SERVER_NAME")
[ -n "$MCP_ID" ] || { echo "MCP server '$MCP_SERVER_NAME' not found - run ./konnect/create-mcp-acl.sh first" >&2; exit 1; }
POLICY_ID=$(find_by_name policies "$POLICY_NAME")

# Only PUT is supported on MCP servers, so send the current object back with
# the new policy list.
set_mcp_policies() {
  curl -s "$API/mcp-servers/$MCP_ID" "${auth[@]}" \
    | jq "del(.id, .created_at, .updated_at, .managed_by) | .policies = (.policies $1)" \
    | curl -s -X PUT "$API/mcp-servers/$MCP_ID" "${auth[@]}" -d @- \
    | jq -c '{name, policies}'
}

if [ "${1:-}" = remove ]; then
  echo "Detaching '$POLICY_NAME' from '$MCP_SERVER_NAME'..."
  set_mcp_policies "- [\"$POLICY_NAME\"]"
  if [ -n "$POLICY_ID" ]; then
    echo "Deleting policy '$POLICY_NAME'..."
    curl -s -o /dev/null -w '  HTTP %{http_code}\n' -X DELETE "$API/policies/$POLICY_ID" "${auth[@]}"
  fi
  exit 0
fi

echo "Policy '$POLICY_NAME' -> $MCP_LOG_ENDPOINT..."
POLICY=$(jq -n --arg name "$POLICY_NAME" --arg url "$MCP_LOG_ENDPOINT" '{
  name: $name,
  display_name: "MCP logs to Vector",
  type: "http-log",
  config: {
    http_endpoint: $url,
    method: "POST",
    content_type: "application/json",
    timeout: 2000,
    keepalive: 60000
  }
}')
if [ -z "$POLICY_ID" ]; then
  curl -s -X POST "$API/policies" "${auth[@]}" -d "$POLICY" | jq -c '{id, name, type, detail}'
else
  curl -s -X PUT "$API/policies/$POLICY_ID" "${auth[@]}" -d "$POLICY" | jq -c '{id, name, type, detail}'
fi

echo "Attaching '$POLICY_NAME' to MCP server '$MCP_SERVER_NAME'..."
set_mcp_policies "- [\"$POLICY_NAME\"] + [\"$POLICY_NAME\"]"
