#!/bin/zsh
# Pulls the latest code, rebuilds, and replaces /Applications/Sermon Trim.app. No manual reinstall needed.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null || brew install xcodegen
git pull --ff-only
xcodegen generate
xcodebuild -project SermonTrim.xcodeproj -scheme SermonTrim -configuration Release -derivedDataPath build build | tail -1
ID="Developer ID Application: Hope Church JC (TCAQTA64TB)"
# Same signing identity on every build keeps macOS privacy permissions (folder/drive access) across updates.
if security find-identity -v -p codesigning | grep -q "$ID"; then
  codesign --force --options runtime --timestamp --sign "$ID" "build/Build/Products/Release/Sermon Trim.app" || true
fi
pkill -x "Sermon Trim" 2>/dev/null || true
rm -rf "/Applications/Sermon Trim.app"
cp -R "build/Build/Products/Release/Sermon Trim.app" "/Applications/Sermon Trim.app"
mkdir -p "$HOME/Library/Application Support/SermonTrim"
git rev-parse HEAD > "$HOME/Library/Application Support/SermonTrim/installed-commit"
open "/Applications/Sermon Trim.app"
echo "Updated to $(git rev-parse --short HEAD)."
