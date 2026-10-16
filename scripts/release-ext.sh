#!/usr/bin/env bash
# Zips the Chrome and Firefox extensions into dist/. With --open, also opens the store consoles to upload them.
# Usage: scripts/release-ext.sh [--open]
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p dist

zip_extension() {
  local dir="$1" out="$PWD/dist/$2"
  rm -f "$out"
  (cd "$dir" && zip -qr "$out" . -x '*.DS_Store' '*__MACOSX*' '*.zip')
  echo "==> $2 ($(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$dir/manifest.json"))"
}

zip_extension web-ext/chrome chrome-extension.zip
zip_extension web-ext/ff firefox-extension.zip

if [[ "${1:-}" == --open ]]; then
  open dist
  open "https://chrome.google.com/u/1/webstore/devconsole/549f90d7-d695-40f5-bc0a-8ae2960da6aa/knknjjghhkppgfkkclcdefohkfdnhfan/edit/package"
  open "https://addons.mozilla.org/en-US/developers/addon/getsprinkles/versions/submit/"
fi
