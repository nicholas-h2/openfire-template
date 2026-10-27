#!/bin/bash
# One-shot provisioning, safe to re-run:
#   1. sets system properties through the admin console: turns on the REST API plugin and
#      points the Certificate Manager plugin at /hotdeploy (where letsencrypt.sh puts certs)
#   2. creates the default MUC room through the REST API if it doesn't exist yet
set -euo pipefail

BASE="${OPENFIRE_URL:-http://openfire:9090}"
API="${BASE}/plugins/restapi/v1"
MUC_SERVICE="conference"
COOKIES="$(mktemp)"
trap 'rm -f "$COOKIES"' EXIT

admin_curl() { curl -fsS -c "$COOKIES" -b "$COOKIES" "$@"; }
csrf_from() { sed -n 's/.*name="csrf" value="\([^"]*\)".*/\1/p' | head -1; }
api() {
  curl -sS -u "admin:${OPENFIRE_ADMIN_PASSWORD}" \
    -H 'Accept: application/json' -H 'Content-Type: application/json' "$@"
}

set_property() {
  local csrf
  csrf="$(admin_curl "${BASE}/server-properties.jsp" | csrf_from)"
  admin_curl -o /dev/null \
    --data-urlencode "csrf=${csrf}" -d action=save -d encrypt=false \
    --data-urlencode "key=$1" --data-urlencode "value=$2" \
    "${BASE}/server-properties.jsp"
  echo "Set system property $1=$2"
}

echo "Waiting for the Openfire admin console..."
until admin_curl -o /dev/null "${BASE}/login.jsp" 2>/dev/null; do sleep 2; done

echo "Logging in to the admin console"
csrf="$(admin_curl "${BASE}/login.jsp" | csrf_from)"
landing="$(admin_curl -o /dev/null -w '%{redirect_url}' \
  --data-urlencode "csrf=${csrf}" -d login=true -d url= \
  --data-urlencode "username=admin" --data-urlencode "password=${OPENFIRE_ADMIN_PASSWORD}" \
  "${BASE}/login.jsp")"
if [[ "$landing" == *login.jsp* || -z "$landing" ]]; then
  echo "Admin console login failed. Check OPENFIRE_ADMIN_PASSWORD." >&2
  exit 1
fi

set_property plugin.restapi.enabled true
# The REST API plugin excludes its URLs from admin console auth with a wildcard pattern,
# which Openfire ignores unless this is on.
set_property adminConsole.access.allow-wildcards-in-excludes true

set_property certificate-manager.directory-watcher.watched-path /hotdeploy
set_property certificate-manager.directory-watcher.replace true
set_property certificate-manager.directory-watcher.enabled true

echo "Waiting for the REST API..."
until [[ "$(api -o /dev/null -w '%{http_code}' "${API}/system/properties")" == 200 ]]; do sleep 2; done

room_jid="${XMPP_ROOM}@${MUC_SERVICE}.${XMPP_DOMAIN}"
status="$(api -o /dev/null -w '%{http_code}' "${API}/chatrooms/${XMPP_ROOM}?servicename=${MUC_SERVICE}")"
if [[ "$status" == 200 ]]; then
  echo "Chat room ${room_jid} already exists"
  exit 0
fi

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
room_json=$(cat <<EOF
{
  "roomName": "$(json_escape "$XMPP_ROOM")",
  "naturalName": "$(json_escape "$XMPP_ROOM_NAME")",
  "description": "$(json_escape "$XMPP_ROOM_DESCRIPTION")",
  "persistent": true,
  "publicRoom": true,
  "canAnyoneDiscoverJID": true,
  "canChangeNickname": true,
  "logEnabled": true,
  "broadcastPresenceRoles": ["moderator", "participant", "visitor"],
  "owners": ["admin@${XMPP_DOMAIN}"],
  "members": ["${XMPP_USER}@${XMPP_DOMAIN}"]
}
EOF
)

status="$(api -o /dev/null -w '%{http_code}' -X POST \
  "${API}/chatrooms?servicename=${MUC_SERVICE}" -d "$room_json")"
if [[ "$status" != 201 ]]; then
  echo "Creating chat room ${room_jid} failed with HTTP ${status}" >&2
  exit 1
fi
echo "Created chat room ${room_jid}"
