#!/usr/bin/env bash
# Docker equivalent of the Konnect "AI Gateway -> New AI Gateway" wizard.
#
# An AI Gateway is its own Konnect resource (POST /v1/ai-gateways) and brings its
# own hybrid cluster endpoints - it is NOT one of the Control Planes listed under
# Gateway Manager, which is why creating a Control Plane alone never makes an
# entry appear in the AI Gateway UI.
#
# This script creates (or reuses) the AI Gateway and provisions the Data Plane
# certificate. The MCP server and its access rules are added afterwards by
# konnect/create-mcp-acl.sh.
#
# Usage:
#   ./konnect/create-ai-gateway.sh                    # PAT from .env, eu (default)
#   KONNECT_REGION=us ./konnect/create-ai-gateway.sh
#
# KONNECT_REGION must match the subdomain of your Konnect UI:
#   eu.cloud.konghq.com -> eu (default), cloud.konghq.com -> us,
#   au.cloud.konghq.com -> au, in.cloud.konghq.com -> in, me.cloud.konghq.com -> me
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$ROOT_DIR/.env"

# PAT (and optionally KONNECT_REGION) come from .env; values already set in
# the environment take precedence.
if [ -f "$ENV_FILE" ]; then
  while IFS='=' read -r key value; do
    case "$key" in ''|\#*) continue ;; esac
    [ -z "${!key:-}" ] && export "$key=$value"
  done < "$ENV_FILE"
fi

: "${PAT:?Set PAT in .env or the environment}"
: "${KONNECT_REGION:=eu}"
# The API only accepts [0-9a-z-] for name; display_name is what the UI shows.
: "${AI_GW_NAME:=ai-gateway-1}"
: "${AI_GW_DISPLAY_NAME:=ai_gateway_1}"

case "$KONNECT_REGION" in
  us|eu|au|in|me) ;;
  *) echo "Unsupported KONNECT_REGION '$KONNECT_REGION' (use us, eu, au, in or me)" >&2; exit 1 ;;
esac

API="https://${KONNECT_REGION}.api.konghq.com"
CERT_DIR="$ROOT_DIR/certs/kong-ai"

auth=(-H "Authorization: Bearer $PAT")

echo "Looking for an existing AI Gateway named '$AI_GW_NAME'..."
AI_GW=$(curl -s "$API/v1/ai-gateways" "${auth[@]}" \
  | jq --arg name "$AI_GW_NAME" '.data[] | select(.name == $name)')

if [ -z "$AI_GW" ]; then
  echo "Not found - creating it..."
  AI_GW=$(curl -s -X POST "$API/v1/ai-gateways" "${auth[@]}" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg name "$AI_GW_NAME" --arg display "$AI_GW_DISPLAY_NAME" \
          '{name: $name, display_name: $display}')")
fi

AI_GW_ID=$(echo "$AI_GW" | jq -r '.id // empty')
if [ -z "$AI_GW_ID" ]; then
  echo "Failed to create the AI Gateway:" >&2
  echo "$AI_GW" | jq . >&2
  exit 1
fi
echo "AI Gateway ID: $AI_GW_ID"

CONTROL_PLANE_HOST=$(echo "$AI_GW" | jq -r '.endpoints.configuration' | sed -E 's#https?://##')
TELEMETRY_HOST=$(echo "$AI_GW" | jq -r '.endpoints.telemetry' | sed -E 's#https?://##')

if [ ! -f "$CERT_DIR/tls.crt" ]; then
  mkdir -p "$CERT_DIR"
  echo "Generating a Data Plane client certificate/key pair..."
  openssl req -new -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$CERT_DIR/tls.key" -out "$CERT_DIR/tls.crt" \
    -days 1095 -subj "/CN=kong-ai-dp"
else
  echo "Reusing the existing certificate in certs/kong-ai/"
fi

# The AI Gateway's id doubles as the Control Plane id for cluster operations.
echo "Registering the certificate with the AI Gateway's cluster..."
curl -s -X POST "$API/v2/control-planes/$AI_GW_ID/dp-client-certificates" "${auth[@]}" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg cert "$(cat "$CERT_DIR/tls.crt")" '{cert: $cert}')" | jq .

# Upsert the AI Data Plane variables consumed by the kong-ai-dp Compose service.
upsert_env() {
  local key="$1" value="$2"
  touch "$ENV_FILE"
  if grep -q "^${key}=" "$ENV_FILE"; then
    # macOS/BSD sed needs the empty -i argument.
    sed -i '' "s#^${key}=.*#${key}=${value}#" "$ENV_FILE"
  else
    echo "${key}=${value}" >> "$ENV_FILE"
  fi
}

upsert_env AI_KONNECT_CLUSTER_CONTROL_PLANE "${CONTROL_PLANE_HOST}:443"
upsert_env AI_KONNECT_CLUSTER_SERVER_NAME "${CONTROL_PLANE_HOST}"
upsert_env AI_KONNECT_CLUSTER_TELEMETRY_ENDPOINT "${TELEMETRY_HOST}:443"
upsert_env AI_KONNECT_CLUSTER_TELEMETRY_SERVER_NAME "${TELEMETRY_HOST}"
upsert_env AI_GATEWAY_ID "$AI_GW_ID"

cat <<EOF

AI Gateway ready: $AI_GW_DISPLAY_NAME ($AI_GW_ID)
Certificate: certs/kong-ai/tls.crt + tls.key
AI_KONNECT_* values written to .env

Next:
  docker compose up -d
  ./konnect/create-mcp-acl.sh
EOF
