#!/bin/zsh
# Pulls the latest code, rebuilds, and replaces /Applications/Sermon Trim.app. No manual reinstall needed.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null || brew install xcodegen
git pull --ff-only
xcodegen generate
xcodebuild -project SermonTrim.xcodeproj -scheme SermonTrim -configuration Release -derivedDataPath build build | tail -1
pkill -x "Sermon Trim" 2>/dev/null || true
rm -rf "/Applications/Sermon Trim.app"
cp -R "build/Build/Products/Release/Sermon Trim.app" "/Applications/Sermon Trim.app"
echo "Updated. Open Sermon Trim from Applications."
