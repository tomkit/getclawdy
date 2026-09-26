#!/bin/bash
set -euo pipefail

# Make Homebrew tools (create-dmg, gh) available in non-interactive shells.
export PATH="/opt/homebrew/bin:$PATH"

# =============================================================================
# release.sh - build, sign, notarize, and publish a Clawdy release.
#
# Pipeline:
#   0. Write the version into project.pbxproj + site/index.html and commit
#      ("release: vX.Y.Z"), so the tag points at sources that say the right version.
#   1. Archive the app (xcodebuild) at the given version.
#   2. Export a Developer ID-signed Clawdy.app.
#   3. Wrap it in a DMG (drag-to-Applications).
#   4. Notarize the DMG with Apple and staple the ticket.
#   5. Generate SHA256SUMS.
#   6. Tag the release (vX.Y.Z) and publish a GitHub Release with the DMG + checksums.
#
# Usage:
#   ./scripts/release.sh 0.0.1          # build number defaults to project.pbxproj's + 1
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
PBXPROJ="Clawdy.xcodeproj/project.pbxproj"
SITE_HTML="site/index.html"

# Rewrite the version in the checked-in sources under $1 (repo root).
# Only touches the MARKETING_VERSION / CURRENT_PROJECT_VERSION keys (every build
# config) and the JSON-LD softwareVersion, so it's safe to re-run.
write_version() {
  local root="$1" version="$2" build="$3"
  sed -i '' -E \
    -e "s/(MARKETING_VERSION = )[^;]+;/\\1${version};/" \
    -e "s/(CURRENT_PROJECT_VERSION = )[^;]+;/\\1${build};/" \
    "${root}/${PBXPROJ}"
  sed -i '' -E "s/(\"softwareVersion\": \")[^\"]*\"/\\1${version}\"/" "${root}/${SITE_HTML}"
}

# Print the build number to use when none is given: the pbxproj's current
# CURRENT_PROJECT_VERSION + 1. If the pbxproj already has this marketing version
# (re-running a release after step 0 committed), reuse its build instead, so the
# re-run doesn't bump it again. Fails if the configs disagree or it's not an integer.
default_build() {
  local root="$1" version="$2" builds
  builds=$(sed -nE 's/.*CURRENT_PROJECT_VERSION = ([^;]+);.*/\1/p' "${root}/${PBXPROJ}" | sort -u)
  if [ "$(printf '%s\n' "$builds" | wc -l | tr -d ' ')" != 1 ]; then
    echo "❌ CURRENT_PROJECT_VERSION differs across configs in ${PBXPROJ}:" $builds >&2; return 1
  fi
  if ! [[ "$builds" =~ ^[0-9]+$ ]]; then
    echo "❌ CURRENT_PROJECT_VERSION in ${PBXPROJ} is '${builds}', not an integer" >&2; return 1
  fi
  if [ "$(grep -c 'MARKETING_VERSION = ' "${root}/${PBXPROJ}")" = \
       "$(grep -cF "MARKETING_VERSION = ${version};" "${root}/${PBXPROJ}")" ]; then
    echo "$builds"
  else
    echo $((builds + 1))
  fi
}

# -- Version --
if [ $# -lt 1 ]; then
  echo "Usage: $0 <version> [build]    e.g. $0 0.0.1"
  exit 1
fi
VERSION="${1#v}"
BUILD_NUMBER="${2:-}"
TAG="v${VERSION}"

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?$ ]]; then
  echo "❌ '$VERSION' is not a SemVer version (e.g. 0.0.1)"; exit 1
fi

if gh release view "$TAG" --repo "$GITHUB_REPO" &>/dev/null; then
  echo "❌ Release $TAG already exists: https://github.com/$GITHUB_REPO/releases/tag/$TAG"
  exit 1
fi

if [ -z "$BUILD_NUMBER" ]; then
  BUILD_NUMBER=$(default_build "$PROJECT_DIR" "$VERSION") || exit 1
  BUILD_NOTE=" (default: ${PBXPROJ} + 1)"
fi

echo ""
echo "🚀 Releasing ${APP_NAME} ${TAG} (build ${BUILD_NUMBER}${BUILD_NOTE:-}) -> ${GITHUB_REPO}"
read -p "   Proceed? (y/N) " -n 1 -r; echo ""
[[ $REPLY =~ ^[Yy]$ ]] || { echo "   Aborted."; exit 0; }

# -- 0. Sync version into the repo --
# Commit only these two paths, so unrelated working-tree changes are left alone.
# Skipped when they already match (re-running for the same version).
echo "📝 Writing ${VERSION} (${BUILD_NUMBER}) into ${PBXPROJ} and ${SITE_HTML}..."
write_version "$PROJECT_DIR" "$VERSION" "$BUILD_NUMBER"
if git -C "$PROJECT_DIR" diff --quiet HEAD -- "$PBXPROJ" "$SITE_HTML"; then
  echo "   (already at ${VERSION}; nothing to commit)"
else
  git -C "$PROJECT_DIR" commit -m "release: ${TAG}" -- "$PBXPROJ" "$SITE_HTML"
fi

# -- 1. Clean --
rm -rf "$BUILD_DIR"
mkdir -p "$EXPORT_DIR" "$DIST_DIR"

# -- 1b. Bundled voice model (git-ignored; downloaded once, checksum-verified) --
"${PROJECT_DIR}/scripts/fetch-models.sh"

# -- 2. Archive --
# No version overrides: the archive uses what step 0 committed, so the shipped
# binary and the tagged sources can't disagree.
echo "📦 Archiving ${APP_NAME} ${VERSION}..."
xcodebuild archive \
  -project "${PROJECT_DIR}/Clawdy.xcodeproj" \
  -scheme "$SCHEME" \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE_PATH" \
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
# The tag push uploads the step-0 commit but doesn't move any branch, so push it
# to main too. Only from main: on another branch, pushing HEAD would publish that
# branch, which is the releaser's call. Never forced; a rejected push just warns.
BRANCH=$(git -C "$PROJECT_DIR" rev-parse --abbrev-ref HEAD)
if [ "$BRANCH" = "main" ]; then
  git -C "$PROJECT_DIR" push origin HEAD || echo "   ⚠️  Push of main failed; push it manually: git push origin HEAD"
else
  echo "   ⚠️  Released from '${BRANCH}', not main: the release commit isn't on origin/main."
  echo "      Push/merge it yourself (git push origin HEAD)."
fi

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
