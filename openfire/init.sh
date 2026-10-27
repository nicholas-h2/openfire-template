#!/bin/bash
# Wraps the image's entrypoint to pre-seed Openfire on first start:
#   - renders openfire.xml (with the <autosetup> block) from the template
#   - stages plugins: REST API (used by provision.sh to create the chat room),
#     inVerse (Converse.js web client at http://localhost:7070/inverse/) and
#     Certificate Manager (installs Let's Encrypt certificates dropped into /hotdeploy)
set -euo pipefail

DATA_DIR="${OPENFIRE_DATA_DIR:-/var/lib/openfire}"
PLUGINS=("restAPI:1.12.0" "inverse:14.0.0.1" "certificatemanager:1.2.0")

# The stock entrypoint copies conf_org into the data volume only when the volume has no
# conf/ yet, so swapping the template in here affects the first start and nothing after.
if [[ ! -d "${DATA_DIR}/conf" ]]; then
  echo "First start: rendering openfire.xml with autosetup for domain ${XMPP_DOMAIN}"
  perl -pe 's/\$\{(\w+)\}/defined $ENV{$1} ? $ENV{$1} : die "missing env var $1\n"/ge' \
    /docker/openfire.xml.template > "${OPENFIRE_DIR}/conf_org/openfire.xml"
fi

# The embedded database lives in OPENFIRE_DIR, which the stock entrypoint doesn't link to the
# data volume. Without this, recreating the container wipes all users and rooms.
mkdir -p "${DATA_DIR}/embedded-db"
ln -sfn "${DATA_DIR}/embedded-db" "${OPENFIRE_DIR}/embedded-db"

mkdir -p /opt/plugins
for plugin in "${PLUGINS[@]}"; do
  name="${plugin%%:*}" version="${plugin##*:}"
  if [[ ! -f "${DATA_DIR}/plugins/${name}.jar" ]]; then
    echo "Downloading ${name} plugin ${version}"
    curl -fsSL -o "/opt/plugins/${name}.jar" \
      "https://www.igniterealtime.org/projects/openfire/plugins/${version}/${name}.jar"
  fi
done

exec /sbin/entrypoint.sh "$@"
