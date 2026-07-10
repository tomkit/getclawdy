# Release scripts

## `release.sh` — cut a Clawdy release

Builds, signs (Developer ID), notarizes, and publishes a Clawdy release to
GitHub Releases on `tomkit/getclawdy`.

```bash
./scripts/release.sh 0.0.1        # marketing version (build number defaults to 1)
./scripts/release.sh 0.0.1 3      # explicit build number
```

What it does:

1. Archives the app with `xcodebuild` at the given version.
2. Exports a Developer ID–signed `Clawdy.app`.
3. Wraps it in a DMG (drag-to-Applications).
4. Notarizes the DMG with Apple and staples the ticket.
5. Generates `SHA256SUMS`.
6. Tags the release (`vX.Y.Z`) and creates a GitHub Release with the DMG + checksums,
   using the matching `CHANGELOG.md` section as the release notes.

It refuses to overwrite an existing release and prompts for confirmation before building.

See [`../RELEASING.md`](../RELEASING.md) for one-time setup (Developer ID certificate,
notarization credentials, `create-dmg` / `gh`) and the full release checklist.
