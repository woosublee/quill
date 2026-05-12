# Unsigned Fork Prerelease Design

**Goal:** Add a safe prerelease path for this fork that can publish a DMG without Apple Developer ID signing or notarization.

**Context:** The existing `release.yml` and `dev-release.yml` workflows assume Developer ID certificate secrets and notarization credentials. Those workflows should remain as references for a future official notarized release path. This fork currently needs a lower-friction prerelease path that clearly communicates the unsigned/non-notarized status.

## Approach

Add a new fork-specific workflow instead of rewriting the upstream-derived release workflows.

- Keep `.github/workflows/release.yml` unchanged as the future notarized release reference.
- Keep `.github/workflows/dev-release.yml` unchanged unless a later task explicitly revisits dev builds.
- Create `.github/workflows/fork-prerelease.yml` for manual prerelease publishing.
- Trigger the workflow with `workflow_dispatch` inputs for tag, release name, and release notes.
- Build a universal DMG using the existing Makefile DMG path.
- Use ad-hoc signing (`CODESIGN_IDENTITY=-`) so the app bundle can be packaged without Developer ID credentials.
- Publish the DMG as a GitHub prerelease with `make_latest: false`.

## Release behavior

The fork prerelease workflow creates or updates a GitHub release for the supplied tag. It uploads a DMG asset named `Quill-Unsigned.dmg` to avoid implying that the artifact is notarized. The release body must state that this is a personal fork prerelease, is not Apple-notarized, and may require the user to bypass Gatekeeper manually.

## Data flow

1. Maintainer manually runs `Fork Prerelease` from GitHub Actions.
2. Workflow validates that the tag looks like a prerelease tag, such as `v0.1.0-alpha.1`.
3. Workflow installs DMG build tools.
4. Workflow builds a universal Quill app and DMG with the existing `Makefile`.
5. Workflow renames the artifact to `Quill-Unsigned.dmg`.
6. Workflow creates or updates the tag and prerelease.
7. GitHub Release displays the warning text and DMG asset.

## Error handling

- Invalid tags fail before building.
- Build failures fail the workflow without creating a release.
- Release upload uses GitHub Actions' release action and updates the prerelease for the same tag.
- The workflow does not attempt notarization and does not require Apple secrets.

## Testing

- Run `make test` locally before merging the workflow.
- Run a local DMG build with `CODESIGN_IDENTITY=-` if the required tools are available.
- Validate the workflow syntax structurally.
- After merge, run one prerelease manually with an alpha tag and confirm the DMG asset appears with the unsigned warning.

## Non-goals

- Do not change the official notarized release workflow.
- Do not add Apple Developer ID signing.
- Do not make this prerelease the latest release.
- Do not claim the DMG is notarized or Gatekeeper-friendly.
