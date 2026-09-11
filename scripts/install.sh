#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"${ROOT}/scripts/build.sh"

pkill -x BrightBar || true
rm -rf /Applications/BrightBar.app
cp -R "${ROOT}/build/BrightBar.app" /Applications/

echo "Installed /Applications/BrightBar.app"
echo "Right-click the menu bar sun icon and enable Launch at Login if you want it to start at login."
echo "macOS may ask you to allow a login item the first time; confirm it in System Settings → General → Login Items."

open /Applications/BrightBar.app
