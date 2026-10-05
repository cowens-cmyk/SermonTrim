#!/bin/zsh
# Publishes a new version: Scripts/release.sh 1.1.0 "What changed"
# Builds the app, makes the DMG, tags the commit, and creates a GitHub release with the DMG attached.
# Every Mac running Sermon Trim then offers the update from Sermon Trim ▸ Check for Updates….
set -euo pipefail
cd "$(dirname "$0")/.."
V="${1:?usage: release.sh <version> [notes]}"
NOTES="${2:-Sermon Trim $V}"
BUILD=$(( $(grep -E 'CURRENT_PROJECT_VERSION' project.yml | head -1 | tr -dc '0-9') + 1 ))
sed -i '' -E "s/MARKETING_VERSION: .*/MARKETING_VERSION: \"$V\"/; s/CURRENT_PROJECT_VERSION: .*/CURRENT_PROJECT_VERSION: \"$BUILD\"/" project.yml
xcodegen generate
xcodebuild -project SermonTrim.xcodeproj -scheme SermonTrim -configuration Release -derivedDataPath build build | tail -1
./Scripts/make_dmg.sh "build/Build/Products/Release/Sermon Trim.app"
git add -A
git commit -m "Release $V" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
git tag "v$V"
git push origin main "v$V"
gh release create "v$V" dist/SermonTrim.dmg --title "Sermon Trim $V" --notes "$NOTES"
echo "Released $V"
