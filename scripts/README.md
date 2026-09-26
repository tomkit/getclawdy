# Release scripts

## `release.sh` — cut a Clawdy release

Builds, signs (Developer ID), notarizes, and publishes a Clawdy release to
GitHub Releases on `tomkit/getclawdy`.

```bash
./scripts/release.sh 0.0.1        # build number defaults to project.pbxproj's + 1
./scripts/release.sh 0.0.1 3      # explicit build number (positive, no leading zeros)
```

Re-running for a version the pbxproj already has reuses its build number instead
of adding 1.

What it does:

1. Writes the version into `project.pbxproj` (`MARKETING_VERSION` /
   `CURRENT_PROJECT_VERSION`, all configs) and `site/index.html` (`softwareVersion`),
   and commits them as `release: vX.Y.Z` (skipped if they already match).
2. Archives the app with `xcodebuild` from those committed values.
3. Exports a Developer ID–signed `Clawdy.app`.
4. Wraps it in a DMG (drag-to-Applications).
5. Notarizes the DMG with Apple and staples the ticket.
6. Generates `SHA256SUMS`.
7. Tags the release (`vX.Y.Z`) and creates a GitHub Release with the DMG + checksums,
   using the matching `CHANGELOG.md` section as the release notes. Pushes the tag, and
   the release commit too when run from `main` (otherwise it warns and you push it).

It refuses to overwrite an existing release, stops before archiving if the tag already
exists at a different commit, and prompts for confirmation before building. A failed
build or notarization leaves the release commit local and unpushed: re-run the same
command, or `git reset HEAD~1` to drop it (working tree kept).

See [`../RELEASING.md`](../RELEASING.md) for one-time setup (Developer ID certificate,
notarization credentials, `create-dmg` / `gh`) and the full release checklist.
