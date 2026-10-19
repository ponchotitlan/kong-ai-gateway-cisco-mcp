#!/usr/bin/env bash
# Keycloak login for the "pyats" MCP server in .mcp.json.
#
#   login    prompt for a kong-realm username/password, exchange them for an
#            offline refresh token and store only that token (never the
#            password) in $SESSION_FILE
#   status   show who is logged in and their mcp_role
#   logout   revoke the stored token and delete it
#   headers  (used as the headersHelper) trade the stored token for a fresh
#            access token and print {"Authorization": "Bearer <jwt>"}
#
# Claude Code runs "headers" on every (re)connect and after a 401/403, with no
# terminal attached, so it can't prompt - run "login" in a terminal first. To
# switch user, run "login" again and reconnect the server with /mcp.
#
# Usage: ./keycloak/mcp-auth.sh login|status|logout|headers
set -euo pipefail

KEYCLOAK_URL="${KEYCLOAK_URL:-http://localhost:8080}"
TOKEN_URL="$KEYCLOAK_URL/realms/kong/protocol/openid-connect/token"
REVOKE_URL="$KEYCLOAK_URL/realms/kong/protocol/openid-connect/revoke"
CLIENT_ID=mcp-client
SESSION_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/pyats-mcp/session"

die() { echo "mcp-auth: $*" >&2; exit 1; }

# Prints a JWT's payload as JSON.
claims() {
  local p
  p=$(cut -d. -f2 <<<"$1" | tr '_-' '/+')
  while [ $(( ${#p} % 4 )) -ne 0 ]; do p="$p="; done
  base64 -d <<<"$p"
}

save_refresh_token() {
  mkdir -p "$(dirname "$SESSION_FILE")"
  # Write via a temp file so a concurrent "headers" never reads half a token.
  (umask 077 && printf '%s\n' "$1" > "$SESSION_FILE.tmp")
  mv "$SESSION_FILE.tmp" "$SESSION_FILE"
}

# Exchanges the stored refresh token; prints the access token and stores
# the rotated refresh token.
refresh() {
  [ -s "$SESSION_FILE" ] || die "not logged in - run: ./keycloak/mcp-auth.sh login"
  local resp
  resp=$(curl -s -m 5 "$TOKEN_URL" \
    -d client_id="$CLIENT_ID" -d grant_type=refresh_token \
    --data-urlencode refresh_token="$(cat "$SESSION_FILE")") \
    || die "Keycloak unreachable at $KEYCLOAK_URL"
  jq -e .access_token >/dev/null <<<"$resp" \
    || die "session expired or revoked ($(jq -r '.error_description // .error' <<<"$resp")) - run: ./keycloak/mcp-auth.sh login"
  save_refresh_token "$(jq -r .refresh_token <<<"$resp")"
  jq -r .access_token <<<"$resp"
}

case "${1:-}" in
  login)
    read -rp "Username: " username
    read -rsp "Password: " password; echo
    resp=$(curl -s -m 5 "$TOKEN_URL" \
      -d client_id="$CLIENT_ID" -d grant_type=password -d scope="openid offline_access" \
      --data-urlencode username="$username" --data-urlencode password="$password") \
      || die "Keycloak unreachable at $KEYCLOAK_URL"
    unset password
    jq -e .refresh_token >/dev/null <<<"$resp" \
      || die "login failed: $(jq -r '.error_description // .error' <<<"$resp")"
    save_refresh_token "$(jq -r .refresh_token <<<"$resp")"
    role=$(claims "$(jq -r .access_token <<<"$resp")" | jq -r '.mcp_role // empty')
    echo "Logged in as $username (mcp_role: ${role:-none - Kong will answer 403})."
    echo "Reconnect the pyats server in Claude Code with /mcp to use this identity."
    ;;
  # Assign before use: a failing $(refresh) inside an argument wouldn't stop
  # the script, and the helper would print an empty Bearer header.
  status)
    access_token=$(refresh)
    claims "$access_token" | jq -r '"Logged in as \(.preferred_username) (mcp_role: \(.mcp_role // "none"))"'
    ;;
  logout)
    if [ -s "$SESSION_FILE" ]; then
      curl -s -m 5 "$REVOKE_URL" -d client_id="$CLIENT_ID" -d token_type_hint=refresh_token \
        --data-urlencode token="$(cat "$SESSION_FILE")" >/dev/null || true
      rm -f "$SESSION_FILE"
    fi
    echo "Logged out."
    ;;
  headers)
    access_token=$(refresh)
    jq -n --arg t "$access_token" '{Authorization: ("Bearer " + $t)}'
    ;;
  *)
    die "usage: $0 login|status|logout|headers"
    ;;
esac
