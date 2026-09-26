# Release scripts

## `release.sh` — cut a Clawdy release

Builds, signs (Developer ID), notarizes, and publishes a Clawdy release to
GitHub Releases on `tomkit/getclawdy`.

```bash
./scripts/release.sh 0.0.1        # marketing version (build number defaults to 1)
./scripts/release.sh 0.0.1 3      # explicit build number
```

What it does:

1. Writes the version into `project.pbxproj` (`MARKETING_VERSION` /
   `CURRENT_PROJECT_VERSION`, all configs) and `site/index.html` (`softwareVersion`),
   and commits them as `release: vX.Y.Z` (skipped if they already match). The script
   pushes only the tag, so push the commit yourself.
2. Archives the app with `xcodebuild` from those committed values.
3. Exports a Developer ID–signed `Clawdy.app`.
4. Wraps it in a DMG (drag-to-Applications).
5. Notarizes the DMG with Apple and staples the ticket.
6. Generates `SHA256SUMS`.
7. Tags the release (`vX.Y.Z`) and creates a GitHub Release with the DMG + checksums,
   using the matching `CHANGELOG.md` section as the release notes.

It refuses to overwrite an existing release and prompts for confirmation before building.

See [`../RELEASING.md`](../RELEASING.md) for one-time setup (Developer ID certificate,
notarization credentials, `create-dmg` / `gh`) and the full release checklist.
