#!/bin/sh
# Obtains and renews a Let's Encrypt certificate with lego, then hands it to Openfire by
# copying it into the hot-deploy volume, which Openfire's Certificate Manager plugin watches.
#
# lego is configured entirely through LEGO_* variables (see letsencrypt.env).
# Without LEGO_DNS it uses the HTTP-01 challenge on port 80.
set -eu

export LEGO_PATH=/data
export LEGO_ACCEPT_TOS=true
if [ -z "${LEGO_DOMAINS:-}" ]; then
  LEGO_DOMAINS="$XMPP_DOMAIN"
  [ "$XMPP_FQDN" != "$XMPP_DOMAIN" ] && LEGO_DOMAINS="$LEGO_DOMAINS,$XMPP_FQDN"
fi
export LEGO_DOMAINS
[ -z "${LEGO_DNS:-}" ] && export LEGO_HTTP=true
: "${LEGO_EMAIL:?Set LEGO_EMAIL in letsencrypt.env}"

CHECK_INTERVAL="${LETSENCRYPT_CHECK_INTERVAL:-43200}"  # 12h between renewal checks
RETRY_INTERVAL="${LETSENCRYPT_RETRY_INTERVAL:-3600}"   # Let's Encrypt limits failed validations per hour
OPENFIRE_UID=100 OPENFIRE_GID=101
NAME="${LEGO_DOMAINS%%,*}"
CRT="/data/certificates/${NAME}.crt"
KEY="/data/certificates/${NAME}.key"

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
  echo "Handing certificate for ${LEGO_DOMAINS} to Openfire"
  put "$KEY" key.pem
  put "$CRT" chain.pem
}

# Clear out the previous copy so Openfire re-imports on every start, in case its data was reset.
rm -f /hotdeploy/key.pem /hotdeploy/chain.pem

while true; do
  echo "Checking certificate for ${LEGO_DOMAINS} ($([ -n "${LEGO_DNS:-}" ] && echo "DNS-01 via ${LEGO_DNS}" || echo "HTTP-01"))"
  if /lego run; then
    deploy
    sleep "$CHECK_INTERVAL"
  else
    echo "Certificate request failed; retrying in ${RETRY_INTERVAL}s" >&2
    deploy
    sleep "$RETRY_INTERVAL"
  fi
done
