#!/usr/bin/env bash
# Prepares the local Keycloak for the pyATS MCP demo:
#   - the "kong" realm
#   - "mcp-client": a public client allowing the password grant (used by
#     keycloak/mcp-auth.sh), whose access tokens carry an "mcp_role" claim
#     read from the user attribute of the same name - Kong maps that claim
#     to the AI Consumer whose ACLs apply
#   - "netops-admin-user" (mcp_role=netops-admin) and "netops-viewer-user"
#     (mcp_role=netops-viewer), both with password "kong"
# Safe to re-run: existing objects are left as they are (Keycloak answers
# 409 Conflict for them).
#
# Usage: KEYCLOAK_URL=http://localhost:8080 ./keycloak/setup.sh
set -euo pipefail

KEYCLOAK_URL="${KEYCLOAK_URL:-http://localhost:8080}"
REALM_URL="$KEYCLOAK_URL/admin/realms/kong"

echo "Get an Admin Token"
TOKEN=$(curl -s "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" \
  -d "client_id=admin-cli" \
  -d "username=admin" \
  -d "password=admin" \
  -d "grant_type=password" \
  | jq -r .access_token)
auth=(-H "Authorization: Bearer $TOKEN")

echo "Create the kong Realm"
curl -s -X POST "$KEYCLOAK_URL/admin/realms" "${auth[@]}" \
  -H "Content-Type: application/json" \
  -d '{
    "realm": "kong",
    "accessTokenLifespan": 3600,
    "enabled": true
  }'

echo "Allow custom user attributes such as mcp_role"
# Keycloak 24+ drops attributes that aren't declared in the user profile.
curl -s "$REALM_URL/users/profile" "${auth[@]}" \
  | jq '.unmanagedAttributePolicy = "ENABLED"' \
  | curl -s -X PUT "$REALM_URL/users/profile" "${auth[@]}" \
      -H "Content-Type: application/json" -d @- >/dev/null

echo "Create the mcp-client Client"
curl -s -X POST "$REALM_URL/clients" "${auth[@]}" \
  -H "Content-Type: application/json" \
  -d '{
    "clientId": "mcp-client",
    "enabled": true,
    "publicClient": true,
    "standardFlowEnabled": false,
    "directAccessGrantsEnabled": true,
    "protocolMappers": [{
      "name": "mcp_role",
      "protocol": "openid-connect",
      "protocolMapper": "oidc-usermodel-attribute-mapper",
      "config": {
        "user.attribute": "mcp_role",
        "claim.name": "mcp_role",
        "jsonType.label": "String",
        "access.token.claim": "true",
        "id.token.claim": "false",
        "userinfo.token.claim": "false"
      }
    }]
  }'

create_user() {
  local username=$1 role=$2
  echo "Create the $username User ($role)"
  curl -s -X POST "$REALM_URL/users" "${auth[@]}" \
    -H "Content-Type: application/json" \
    -d '{
      "username": "'"$username"'",
      "email": "'"$username"'@example.com",
      "firstName": "'"$username"'",
      "lastName": "Demo",
      "emailVerified": true,
      "enabled": true,
      "attributes": { "mcp_role": ["'"$role"'"] },
      "credentials": [{ "type": "password", "value": "kong", "temporary": false }]
    }'
}

create_user netops-admin-user netops-admin
create_user netops-viewer-user netops-viewer

echo
echo "Done. Log in for Claude Code with: ./keycloak/mcp-auth.sh login"
