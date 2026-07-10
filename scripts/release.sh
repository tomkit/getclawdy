#!/bin/bash
set -euo pipefail

# Make Homebrew tools (create-dmg, gh) available in non-interactive shells.
export PATH="/opt/homebrew/bin:$PATH"

# =============================================================================
# release.sh - build, sign, notarize, and publish a Clawdy release.
#
# Pipeline:
#   1. Archive the app (xcodebuild) at the given version.
#   2. Export a Developer ID-signed Clawdy.app.
#   3. Wrap it in a DMG (drag-to-Applications).
#   4. Notarize the DMG with Apple and staple the ticket.
#   5. Generate SHA256SUMS.
#   6. Tag the release (vX.Y.Z) and publish a GitHub Release with the DMG + checksums.
#
# Usage:
#   ./scripts/release.sh 0.0.1          # marketing version, build number defaults to 1
#   ./scripts/release.sh 0.0.1 3        # explicit build number
#
# One-time prerequisites (see RELEASING.md):
#   - "Developer ID Application" certificate in your login keychain
#   - brew install create-dmg gh ; gh auth login
#   - xcrun notarytool store-credentials "CLAWDY_NOTARY" --apple-id <id> --team-id M2U28D32J3 --password <app-specific-pw>
# =============================================================================

SCHEME="Clawdy"
APP_NAME="Clawdy"
GITHUB_REPO="tomkit/getclawdy"
TEAM_ID="M2U28D32J3"
NOTARY_PROFILE="CLAWDY_NOTARY"

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${PROJECT_DIR}/build"
ARCHIVE_PATH="${BUILD_DIR}/${APP_NAME}.xcarchive"
EXPORT_DIR="${BUILD_DIR}/export"
DIST_DIR="${BUILD_DIR}/dist"
DMG_BACKGROUND="${PROJECT_DIR}/dmg-background.png"
DMG_PATH="${DIST_DIR}/${APP_NAME}.dmg"

# -- Version --
if [ $# -lt 1 ]; then
  echo "Usage: $0 <version> [build]    e.g. $0 0.0.1"
  exit 1
fi
VERSION="${1#v}"
BUILD_NUMBER="${2:-1}"
TAG="v${VERSION}"

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?$ ]]; then
  echo "❌ '$VERSION' is not a SemVer version (e.g. 0.0.1)"; exit 1
fi

if gh release view "$TAG" --repo "$GITHUB_REPO" &>/dev/null; then
  echo "❌ Release $TAG already exists: https://github.com/$GITHUB_REPO/releases/tag/$TAG"
  exit 1
fi

echo ""
echo "🚀 Releasing ${APP_NAME} ${TAG} (build ${BUILD_NUMBER}) -> ${GITHUB_REPO}"
read -p "   Proceed? (y/N) " -n 1 -r; echo ""
[[ $REPLY =~ ^[Yy]$ ]] || { echo "   Aborted."; exit 0; }

# -- 1. Clean --
rm -rf "$BUILD_DIR"
mkdir -p "$EXPORT_DIR" "$DIST_DIR"

# -- 2. Archive --
echo "📦 Archiving ${APP_NAME} ${VERSION}..."
xcodebuild archive \
  -project "${PROJECT_DIR}/Clawdy.xcodeproj" \
  -scheme "$SCHEME" \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE_PATH" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  2>&1 | tail -5

# -- 3. Export (Developer ID signed) --
echo "📤 Exporting Developer ID-signed ${APP_NAME}.app..."
cat > "${BUILD_DIR}/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>teamID</key><string>${TEAM_ID}</string>
    <key>destination</key><string>export</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "${BUILD_DIR}/ExportOptions.plist" \
  2>&1 | tail -5

APP_PATH="${EXPORT_DIR}/${APP_NAME}.app"
[ -d "$APP_PATH" ] || { echo "❌ Export did not produce ${APP_PATH}"; exit 1; }

# -- 4. DMG --
echo "💿 Building DMG..."
create-dmg \
  --volname "${APP_NAME}" \
  --window-pos 200 120 \
  --window-size 660 400 \
  --icon-size 100 \
  --icon "${APP_NAME}.app" 160 195 \
  --app-drop-link 500 195 \
  --background "${DMG_BACKGROUND}" \
  "$DMG_PATH" \
  "$APP_PATH" \
  2>&1 | tail -3

# -- 5. Notarize + staple --
echo "🔏 Notarizing DMG with Apple (may take a few minutes)..."
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
echo "📎 Stapling ticket..."
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"

# -- 6. Checksums --
echo "🧾 Generating SHA256SUMS..."
( cd "$DIST_DIR" && shasum -a 256 "$(basename "$DMG_PATH")" > SHA256SUMS && cat SHA256SUMS )

# -- 7. Tag --
echo "🏷️  Tagging ${TAG}..."
git -C "$PROJECT_DIR" tag -a "$TAG" -m "Clawdy ${TAG}" 2>/dev/null || echo "   (tag ${TAG} already exists locally)"
git -C "$PROJECT_DIR" push origin "$TAG" || echo "   (push the tag manually: git push origin ${TAG})"

# -- 8. GitHub Release (notes pulled from CHANGELOG.md) --
NOTES=$(awk "/^## \\[${VERSION}\\]/{f=1;next} /^## \\[/{f=0} f" "${PROJECT_DIR}/CHANGELOG.md")
echo "🏷️  Creating GitHub Release ${TAG}..."
gh release create "$TAG" "$DMG_PATH" "${DIST_DIR}/SHA256SUMS" \
  --repo "$GITHUB_REPO" \
  --title "Clawdy ${TAG}" \
  --notes "${NOTES:-Clawdy ${TAG}}" \
  --latest

echo ""
echo "✅ Clawdy ${TAG} published: https://github.com/${GITHUB_REPO}/releases/tag/${TAG}"
echo "   Always-latest download: https://github.com/${GITHUB_REPO}/releases/latest/download/${APP_NAME}.dmg"
