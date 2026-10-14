#!/bin/bash
# Publish a Headroom release that installed copies find on their own:
#   signed (Developer ID) + notarized + stapled zip, and update.json, on a GitHub release.
#
#   HEADROOM_SIGN_ID="Developer ID Application: …"   (security find-identity -v -p codesigning)
#   HEADROOM_NOTARY_PROFILE=<profile>   one-time: xcrun notarytool store-credentials <profile> \
#                                         --apple-id <you> --team-id <TEAM> --password <app-specific password>
#   HEADROOM_RELEASE_REPO=owner/repo     a PUBLIC repo — installed apps read the feed without a login
#
#   ./scripts/release.sh "What's new in one line"
# Bump VERSION first. The feed every build checks: https://github.com/$REPO/releases/latest/download/update.json
set -euo pipefail
cd "$(dirname "$0")/.."
: "${HEADROOM_SIGN_ID:?set HEADROOM_SIGN_ID}" "${HEADROOM_NOTARY_PROFILE:?set HEADROOM_NOTARY_PROFILE}" "${HEADROOM_RELEASE_REPO:?set HEADROOM_RELEASE_REPO}"
VERSION=$(cat VERSION)
NOTES="${1:-Headroom $VERSION}"
REPO="$HEADROOM_RELEASE_REPO"
if gh release view "v$VERSION" --repo "$REPO" >/dev/null 2>&1; then echo "v$VERSION already exists on $REPO — bump VERSION"; exit 1; fi

export HEADROOM_UPDATE_FEED="https://github.com/$REPO/releases/latest/download/update.json"
./scripts/bundle.sh --no-install            # signs, notarizes, staples → dist/Headroom.zip
[ -f dist/Headroom.zip ] || { echo "no notarized zip — check the notary profile"; exit 1; }

python3 - "$VERSION" "https://github.com/$REPO/releases/download/v$VERSION/Headroom.zip" "$NOTES" > dist/update.json <<'PY'
import json, sys
print(json.dumps({"version": sys.argv[1], "url": sys.argv[2], "notes": sys.argv[3], "minimumSystem": "15.0"}, indent=2))
PY
gh release create "v$VERSION" dist/Headroom.zip dist/update.json --repo "$REPO" --title "Headroom $VERSION" --notes "$NOTES"
echo "released v$VERSION — every copy built with this feed sees it within a day"
