#!/usr/bin/env bash
# Starts Azurite (Microsoft's Azure Blob emulator, native Node) on localhost and exports
# MACSH_IT_AZ_* variables to $GITHUB_ENV. Meant for macOS CI runners.
set -euo pipefail

D=/tmp/macsh-azurite
rm -rf "$D"; mkdir -p "$D"
command -v rclone >/dev/null || brew install rclone
export_env() { echo "$1=$2" >> "${GITHUB_ENV:-/dev/null}"; }

# Azurite's published, well-known development account (not a secret).
ACCOUNT=devstoreaccount1
KEY='Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw=='
ENDPOINT="http://127.0.0.1:10000/$ACCOUNT"

(cd "$D" && npm install --no-audit --no-fund azurite@3.33.0)
nohup "$D/node_modules/.bin/azurite-blob" --silent --location "$D/data" --blobHost 127.0.0.1 \
  --skipApiVersionCheck > "$D/azurite.log" 2>&1 &
for _ in $(seq 1 40); do nc -z 127.0.0.1 10000 && break; sleep 0.5; done
nc -z 127.0.0.1 10000 || { echo "Azurite did not start"; cat "$D/azurite.log"; exit 1; }

# Create the container the tests use (setup only; the tests go through macsh).
RCLONE_CONFIG_AZ_TYPE=azureblob RCLONE_CONFIG_AZ_ACCOUNT=$ACCOUNT RCLONE_CONFIG_AZ_KEY=$KEY \
  RCLONE_CONFIG_AZ_ENDPOINT=$ENDPOINT rclone mkdir az:macshbox

export_env MACSH_IT_AZ_ACCOUNT "$ACCOUNT"
export_env MACSH_IT_AZ_KEY "$KEY"
export_env MACSH_IT_AZ_ENDPOINT "$ENDPOINT"
export_env MACSH_IT_AZ_CONTAINER macshbox
echo "azurite up"
