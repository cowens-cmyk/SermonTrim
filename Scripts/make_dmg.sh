#!/bin/zsh
# Builds dist/SermonTrim.dmg from the installed (or freshly built) app: drag-to-Applications layout.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${1:-/Applications/Sermon Trim.app}"
[ -d "$APP" ] || { echo "App not found: $APP"; exit 1; }
STAGE="$(mktemp -d)"
mkdir -p dist
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f dist/SermonTrim.dmg
hdiutil create -volname "Sermon Trim" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ dist/SermonTrim.dmg >/dev/null
rm -rf "${STAGE:?}"
echo "Created dist/SermonTrim.dmg ($(du -h dist/SermonTrim.dmg | cut -f1))"
