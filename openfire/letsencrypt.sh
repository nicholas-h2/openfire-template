#!/bin/sh
# Obtains and renews a Let's Encrypt certificate with lego (HTTP-01 challenge on port 80), then
# hands it to Openfire by copying it into the hot-deploy volume, which Openfire's Certificate
# Manager plugin watches.
set -eu

: "${LETSENCRYPT_EMAIL:?Set LETSENCRYPT_EMAIL in .env}"
DOMAINS="${LETSENCRYPT_DOMAINS:-$XMPP_DOMAIN}"
NAME="${DOMAINS%%,*}"
CRT="/data/certificates/${NAME}.crt"
KEY="/data/certificates/${NAME}.key"
CHECK_INTERVAL=43200   # 12h between renewal checks
RETRY_INTERVAL=3600    # Let's Encrypt limits failed validations per hour
OPENFIRE_UID=100 OPENFIRE_GID=101

# Stages in a subdirectory (same volume, so the rename is atomic) because the plugin tries to
# install any file that appears in /hotdeploy itself, including half-written temp files.
put() {
  mkdir -p /hotdeploy/.staging
  install -m 0640 -o "$OPENFIRE_UID" -g "$OPENFIRE_GID" "$1" "/hotdeploy/.staging/$2"
  mv -f "/hotdeploy/.staging/$2" "/hotdeploy/$2"
}

deploy() {
  [ -f "$CRT" ] && [ -f "$KEY" ] || return 0
  if cmp -s "$CRT" /hotdeploy/chain.pem && cmp -s "$KEY" /hotdeploy/key.pem; then return 0; fi
  echo "Handing certificate for ${DOMAINS} to Openfire"
  put "$KEY" key.pem
  put "$CRT" chain.pem
}

# Clear out the previous copy so Openfire re-imports on every start, in case its data was reset.
rm -f /hotdeploy/key.pem /hotdeploy/chain.pem

while true; do
  echo "Checking certificate for ${DOMAINS}"
  if /lego run --accept-tos --http --path /data --email "$LETSENCRYPT_EMAIL" --domains "$DOMAINS"; then
    deploy
    sleep "$CHECK_INTERVAL"
  else
    echo "Certificate request failed; retrying in ${RETRY_INTERVAL}s" >&2
    deploy
    sleep "$RETRY_INTERVAL"
  fi
done
