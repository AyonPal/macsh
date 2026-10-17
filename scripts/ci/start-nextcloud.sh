#!/usr/bin/env bash
# Installs and starts a real Nextcloud (PHP built-in server + SQLite) on a macOS CI runner.
# Docker/Podman cannot run on Apple Silicon runners (no nested virtualization), so this
# runs Nextcloud natively. Exports MACSH_IT_* variables to $GITHUB_ENV when set.
set -euo pipefail

PORT="${NEXTCLOUD_PORT:-8080}"
ADMIN_USER="admin"
ADMIN_PASS="$(openssl rand -hex 12)"
DIR="${NEXTCLOUD_DIR:-$RUNNER_TEMP/nextcloud-it}"
mkdir -p "$DIR"

command -v php >/dev/null || brew install php
command -v rclone >/dev/null || brew install rclone

curl -fsSL https://download.nextcloud.com/server/releases/latest.tar.bz2 -o "$DIR/nextcloud.tar.bz2"
tar -xjf "$DIR/nextcloud.tar.bz2" -C "$DIR"
cd "$DIR/nextcloud"

OCC=(php -d memory_limit=1G occ)
"${OCC[@]}" maintenance:install --database sqlite \
  --admin-user "$ADMIN_USER" --admin-pass "$ADMIN_PASS" --data-dir "$DIR/data"
"${OCC[@]}" config:system:set trusted_domains 1 --value="127.0.0.1:$PORT"
"${OCC[@]}" config:system:set overwrite.cli.url --value="http://127.0.0.1:$PORT"

PHP_CLI_SERVER_WORKERS=4 nohup php -d memory_limit=1G -S "127.0.0.1:$PORT" -t "$DIR/nextcloud" \
  > "$DIR/server.log" 2>&1 &

for _ in $(seq 1 60); do
  if curl -fsS "http://127.0.0.1:$PORT/status.php" | grep -q '"installed":true'; then break; fi
  sleep 1
done
curl -fsS "http://127.0.0.1:$PORT/status.php"
echo

# The same URL a user would enter in macsh, and a sanity check that WebDAV auth works.
URL="http://127.0.0.1:$PORT/remote.php/dav/files/$ADMIN_USER/"
curl -fsS -o /dev/null -X PROPFIND -H "Depth: 0" -u "$ADMIN_USER:$ADMIN_PASS" "$URL"

if [ -n "${GITHUB_ENV:-}" ]; then
  {
    echo "MACSH_IT_NEXTCLOUD_URL=$URL"
    echo "MACSH_IT_NEXTCLOUD_USER=$ADMIN_USER"
    echo "MACSH_IT_NEXTCLOUD_PASS=$ADMIN_PASS"
  } >> "$GITHUB_ENV"
  echo "::add-mask::$ADMIN_PASS"
fi
