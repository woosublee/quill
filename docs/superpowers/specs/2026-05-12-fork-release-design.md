# Fork Release Design

**Goal:** Add a safe release path for this fork that can publish a DMG without Apple Developer ID signing or notarization, while presenting it as the fork's normal GitHub release.

**Context:** The existing `release.yml` and `dev-release.yml` workflows assume Developer ID certificate secrets and notarization credentials. Those workflows should remain as references for a future official notarized release path. This fork currently needs a lower-friction release path that works before Apple Developer enrollment is available.

## Approach

Add a new fork-specific workflow instead of rewriting the upstream-derived release workflows.

- Keep `.github/workflows/release.yml` unchanged as the future notarized release reference.
- Keep `.github/workflows/dev-release.yml` unchanged unless a later task explicitly revisits dev builds.
- Create `.github/workflows/fork-release.yml` for manual release publishing.
- Trigger the workflow with `workflow_dispatch` inputs for tag, release name, and release notes.
- Build a universal DMG using the existing Makefile DMG path.
- Use ad-hoc signing (`CODESIGN_IDENTITY=-`) so the app bundle can be packaged without Developer ID credentials.
- Publish `vX.Y.Z` tags as normal latest releases.
- Publish `vX.Y.Z-alpha.N`, `vX.Y.Z-beta.N`, and `vX.Y.Z-rc.N` tags as GitHub prereleases that are not latest.

## Release behavior

The fork release workflow creates or updates a GitHub release for the supplied tag. It uploads a DMG asset named `Quill.dmg` so the release looks like the fork's normal downloadable build. Tags with a prerelease suffix become GitHub prereleases; plain semantic version tags become latest releases. The release body includes a concise installation note that macOS may show a first-launch security warning and that users should only run the build if they trust this fork.

## Data flow

1. Maintainer manually runs `Fork Release` from GitHub Actions.
2. Workflow validates that the tag looks like a release tag, such as `v0.1.0` or `v0.1.0-beta.1`.
3. Workflow derives `prerelease` and `make_latest` from whether the tag contains a prerelease suffix.
4. Workflow installs DMG build tools.
5. Workflow builds a universal Quill app and DMG with the existing `Makefile`.
6. Workflow renames the artifact to `Quill.dmg`.
7. Workflow creates or updates the tag and release.
8. GitHub Release displays the installation note and DMG asset.

## Error handling

- Invalid tags fail before building.
- Build failures fail the workflow without creating a release.
- Release upload uses GitHub Actions' release action and updates the release for the same tag.
- The workflow does not attempt notarization and does not require Apple secrets.

## Testing

- Run `make test` locally before merging the workflow.
- Run a local DMG build with `CODESIGN_IDENTITY=-` if the required tools are available.
- Validate the workflow syntax structurally.
- After merge, run one release manually with the first tag and confirm the DMG asset appears with the installation note.

## Versioning

Use `v0.1.0-beta.1` if the first public build should be marked as prerelease quality in GitHub, or `v0.1.0` if it should be published as the latest release. Increment prerelease suffixes for testing iterations, for example `v0.1.0-beta.2`, then publish `v0.1.0` when that line is ready to be the latest release. Increment patch versions for follow-up fixes, for example `v0.1.1`, and reserve minor versions for user-visible feature batches.

## Inherited tag strategy

The fork currently contains many upstream-inherited tags, including historical `build-*` tags and upstream semantic version tags such as `v0.3.x`. Do not delete those tags as part of this workflow change. Treat them as historical upstream references unless they block a fork release. Start fork-owned release numbering from a lower, explicit fork line such as `v0.1.0-beta.1` or `v0.1.0`, and avoid reusing existing upstream tag names. If tag cleanup becomes necessary later, handle it as a separate maintenance task with explicit review because deleting remote tags affects shared repository history.

## Non-goals

- Do not change the official notarized release workflow.
- Do not add Apple Developer ID signing.
- Do not foreground the build as unsigned in release names or asset names.
- Do not claim the DMG is Apple-notarized or Gatekeeper-friendly.
