# Releasing Clawdy

Clawdy ships as a **signed + notarized DMG** attached to a **GitHub Release** on
`tomkit/getclawdy`. Versions follow [SemVer](https://semver.org) and each release
has a matching git tag (`vX.Y.Z`) and a`CHANGELOG.md` entry.

## One-time setup

You need an Apple Developer Program membership (team `M2U28D32J3`) and:

1. **Developer ID Application certificate** — the identity that lets a directly-downloaded
   app pass Gatekeeper. Create it in Xcode -> Settings -> Accounts -> (your team) ->
   Manage Certificates -> + -> **Developer ID Application**. (An *Apple Distribution*
   cert is App-Store-only and will NOT work for a direct download.) Confirm with:
   ```bash
   security find-identity -v -p codesigning | grep "Developer ID Application"
   ```
2. **Notarization credentials**, stored once in your keychain:
   ```bash
   xcrun notarytool store-credentials "CLAWDY_NOTARY" \
     --apple-id "you@example.com" --team-id M2U28D32J3 \
     --password "<app-specific-password>"
   ```
   (Create the app-specific password at appleid.apple.com -> Sign-In & Security.)
3. **Tools**: `brew install create-dmg gh` and `gh auth login`.
4. **Hardened Runtime** must be enabled on the app target (required for notarization).

## Cutting a release

1. Land all changes on `main` and update `CHANGELOG.md` (move items from `[Unreleased]`
   into a new `## [X.Y.Z] - YYYY-MM-DD` section).
2. Run the release script with the new version:
   ```bash
   ./scripts/release.sh 0.0.1
   ```
   The build number defaults to the pbxproj's `CURRENT_PROJECT_VERSION` + 1 (shown in the
   confirmation prompt); pass it explicitly to override: `./scripts/release.sh 0.0.5 7`.
   It must be a positive integer without leading zeros. Re-running for a version the
   pbxproj already has reuses that build rather than adding 1.
   It first writes the version into `Clawdy.xcodeproj/project.pbxproj` (`MARKETING_VERSION`
   and `CURRENT_PROJECT_VERSION`, every config) and `site/index.html` (`softwareVersion`) and
   commits them as `release: vX.Y.Z`, so the tag points at sources that say the right
   version. Then it archives, exports a Developer ID-signed `Clawdy.app`, wraps it in a DMG,
   submits the DMG to Apple for notarization, staples the ticket, generates `SHA256SUMS`,
   creates the `v0.0.1` git tag, pushes the tag and (when run from `main`) the release commit, and
   publishes a GitHub Release with the DMG + checksums + changelog notes. From another
   branch it warns and leaves pushing the release commit to you.

   If the build or notarization fails, the `release: vX.Y.Z` commit stays local and
   unpushed. Re-run the same command (it reuses the commit), or drop it with
   `git reset HEAD~1` (keeps your working tree) if you want to change something. If the
   tag already exists at a different commit, the script stops before archiving; delete
   the stale tag (locally and on origin) or release a new version.
3. If `README.md` lists per-release checksums, add the new SHA-256 (from `SHA256SUMS`) by
   hand and commit it; the script doesn't touch `README.md`.
4. Verify the published release page, then announce.

## What makes the download trustworthy

- **Developer ID signature** — proves the binary came from your Apple team and hasn't been tampered with.
- **Apple notarization + stapled ticket** — Apple scanned the binary; Gatekeeper opens it without warnings, even offline.
- **`SHA256SUMS`** — users can verify the download integrity: `shasum -a 256 -c SHA256SUMS`.

## Future enhancements (not required for a release)

- **In-app auto-update** via Sparkle (the framework is already bundled but the updater is disabled):
  enable the updater, generate a signed `appcast.xml` per release, and host it.
- **Homebrew cask** so users can `brew install --cask clawdy`.
