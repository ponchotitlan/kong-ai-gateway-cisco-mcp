#!/usr/bin/env bash
# Puts the pyats-tools MCP server behind Keycloak and restricts its config
# tools to admins:
#   - the "pyats-tools" MCP server itself (passthrough listener on
#     /pyats-tools -> http://pyats-mcp:8000/mcp), created if missing
#   - "keycloak-kong" AI Auth Strategy (openid-connect, kong realm). The
#     token's mcp_role claim selects the AI Consumer, so a token without a
#     known role is rejected.
#   - "netops-admin" / "netops-viewer" AI Consumers, one per role. Users live
#     only in Keycloak (see keycloak/setup.sh).
#   - access rules on pyats-tools: both roles may connect and use the
#     read-only tools; ADMIN_TOOLS are netops-admin only.
# Safe to re-run: existing strategy/consumers are reused and the MCP server
# is rewritten with the same access block.
#
# Usage: ./konnect/create-mcp-acl.sh   (reads PAT and AI_GATEWAY_ID from .env)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
set -a; . "$ROOT_DIR/.env"; set +a

: "${PAT:?Set PAT in .env}"
: "${AI_GATEWAY_ID:?Set AI_GATEWAY_ID in .env}"
: "${KONNECT_REGION:=eu}"
: "${MCP_SERVER_NAME:=pyats-tools}"
: "${MCP_UPSTREAM_URL:=http://pyats-mcp:8000/mcp}"
: "${OIDC_ISSUER:=http://keycloak:8080/realms/kong}"

ADMIN_TOOLS='["pyats_configure_device","pyats_run_linux_command","pyats_run_dynamic_test","pyats_load_external_inventory"]'

API="https://${KONNECT_REGION}.api.konghq.com/v1/ai-gateways/$AI_GATEWAY_ID"
auth=(-H "Authorization: Bearer $PAT" -H "Content-Type: application/json")

find_by_name() {
  curl -s "$API/$1" "${auth[@]}" | jq -r --arg n "$2" '.data[] | select(.name == $n) | .id'
}

echo "Auth strategy 'keycloak-kong'..."
STRATEGY=$(jq -n --arg issuer "$OIDC_ISSUER" '{
  name: "keycloak-kong",
  display_name: "Keycloak (kong realm)",
  type: "openid-connect",
  config: {
    issuer: $issuer,
    auth_methods: ["bearer"],
    cache_tokens_salt: "keycloak-kong-mcp",
    consumer_claims: [["mcp_role"]],
    consumer_by: ["username"],
    consumer_optional: false,
    upstream_headers_claims: ["preferred_username"],
    upstream_headers_names: ["X-Authenticated-User"]
  }
}')
STRATEGY_ID=$(find_by_name auth-strategies keycloak-kong)
if [ -z "$STRATEGY_ID" ]; then
  curl -s -X POST "$API/auth-strategies" "${auth[@]}" -d "$STRATEGY" | jq -c '{id, name}'
else
  curl -s -X PUT "$API/auth-strategies/$STRATEGY_ID" "${auth[@]}" -d "$STRATEGY" | jq -c '{id, name, message}'
fi

for role in netops-admin netops-viewer; do
  echo "AI Consumer '$role'..."
  if [ -z "$(find_by_name consumers "$role")" ]; then
    curl -s -X POST "$API/consumers" "${auth[@]}" \
      -d "$(jq -n --arg r "$role" '{name: $r, display_name: "\($r) (Keycloak mcp_role)", type: "oauth"}')" \
      | jq -c '{id, name}'
  else
    echo "  already exists"
  fi
done

echo "MCP server '$MCP_SERVER_NAME'..."
MCP_ID=$(find_by_name mcp-servers "$MCP_SERVER_NAME")
if [ -z "$MCP_ID" ]; then
  # Same settings as the server originally created in the Konnect UI.
  MCP_ID=$(curl -s -X POST "$API/mcp-servers" "${auth[@]}" \
    -d "$(jq -n --arg name "$MCP_SERVER_NAME" --arg url "$MCP_UPSTREAM_URL" '{
      name: $name,
      display_name: "pyATS Tools",
      type: "passthrough-listener",
      enabled: true,
      config: {
        url: $url,
        route: {paths: ["/\($name)"]},
        logging: {audits: true, payloads: true}
      }
    }')" | jq -r '.id // empty')
  [ -n "$MCP_ID" ] || { echo "Failed to create MCP server '$MCP_SERVER_NAME'" >&2; exit 1; }
  echo "  created on route /$MCP_SERVER_NAME -> $MCP_UPSTREAM_URL"
else
  echo "  already exists"
fi

echo "Access rules on MCP server '$MCP_SERVER_NAME'..."

# Only PUT is supported, so send the current object back with a new access
# block and tool list. A per-tool ACL replaces the default one entirely.
curl -s "$API/mcp-servers/$MCP_ID" "${auth[@]}" \
  | jq --argjson admin_tools "$ADMIN_TOOLS" '
      del(.id, .created_at, .updated_at, .managed_by)
      | .access = {
          auth_strategies: ["keycloak-kong"],
          acl_attribute_type: "consumer",
          acls: {allow: ["netops-admin", "netops-viewer"]},
          default_tool_acls: {allow: ["netops-admin", "netops-viewer"]}
        }
      | .tools = [$admin_tools[] | {name: ., access: {acls: {allow: ["netops-admin"]}}}]' \
  | curl -s -X PUT "$API/mcp-servers/$MCP_ID" "${auth[@]}" -d @- \
  | jq -c '{name, acl_attribute_type: .access.acl_attribute_type, admin_only: [.tools[].name]}'
