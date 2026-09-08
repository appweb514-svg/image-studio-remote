#!/bin/bash
# Builds the web UI and copies dist/ into the app's Resources/webui_dist,
# which the Swift app serves as static files.
set -euo pipefail
cd "$(dirname "$0")"

if [ -f package-lock.json ]; then
  npm ci
else
  npm install
fi

npm run build

RESOURCES_DIR="../Resources"
rm -rf "$RESOURCES_DIR/webui_dist"
cp -R dist "$RESOURCES_DIR/webui_dist"
echo "webui_dist updated: $(pwd)/$RESOURCES_DIR/webui_dist"
