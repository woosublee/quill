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
- Publish the DMG as a normal GitHub release with `make_latest: true`.

## Release behavior

The fork release workflow creates or updates a GitHub release for the supplied tag. It uploads a DMG asset named `Quill.dmg` so the release looks like the fork's normal downloadable build. The release body includes a concise installation note that macOS may show a first-launch security warning and that users should only run the build if they trust this fork.

## Data flow

1. Maintainer manually runs `Fork Release` from GitHub Actions.
2. Workflow validates that the tag looks like a release tag, such as `v0.1.0`.
3. Workflow installs DMG build tools.
4. Workflow builds a universal Quill app and DMG with the existing `Makefile`.
5. Workflow renames the artifact to `Quill.dmg`.
6. Workflow creates or updates the tag and release.
7. GitHub Release displays the installation note and DMG asset.

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

Use `v0.1.0` for the first fork release. Increment patch versions for follow-up fixes, for example `v0.1.1`, and reserve minor versions for user-visible feature batches.

## Non-goals

- Do not change the official notarized release workflow.
- Do not add Apple Developer ID signing.
- Do not foreground the build as unsigned in release names or asset names.
- Do not claim the DMG is Apple-notarized or Gatekeeper-friendly.
