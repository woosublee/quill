---
name: freeflow-release
description: Prepare and publish FreeFlow app releases. Use when the user asks to release FreeFlow, prepare a new version, bump the FreeFlow version, write or update FreeFlow changelog entries, validate a FreeFlow semver release, create a vX.Y.Z tag, or publish a signed FreeFlow DMG through the repository GitHub Actions release workflow.
---

# Quill Release

## Overview

Use this skill to prepare a Quill release from the local repository. Quill currently uses `.github/workflows/manual-release.yml` for public fork releases: start the workflow manually, provide the release tag and build number, and let it stamp the app bundle, extract the matching `CHANGELOG.md` section, build the DMG, and create the GitHub Release.

Public release tags no longer trigger `.github/workflows/release.yml` automatically. The notarized release workflow is `workflow_dispatch` only until Apple notarization secrets are ready; it keeps a commented tag trigger example in the workflow file for re-enabling later.

Every release prep must update `CHANGELOG.md` by comparing the previous public Quill release with the current release target. The changelog section should describe the user-visible changes that shipped since the previous release, not just summarize the final release-prep commit.

## Ground Rules

- Treat `CHANGELOG.md` as the release notes source of truth, and update it before any release commit or tag.
- Keep changelog language user-facing. Avoid implementation details unless they affect maintainers or troubleshooting.
- Do not edit `README.md` or unrelated docs unless the user explicitly asks.
- Do not push tags or branches until the user has approved the exact release version and changelog.
- Never use `git reset --hard` or destructive cleanup while preparing a release.
- Preserve unrelated working tree changes. If unrelated changes exist, report them and avoid staging them.

## Release Workflow

1. Inspect current state:
   ```bash
   git status --short --branch
   git log --oneline --decorate -n 20
   ```

2. Find the previous public release:
   ```bash
   git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-version:refname
   git describe --tags --match 'v[0-9]*.[0-9]*.[0-9]*' --abbrev=0
   git log --oneline --decorate -- Info.plist CHANGELOG.md .github/workflows/manual-release.yml .github/workflows/release.yml
   git blame -L 11,14 Info.plist
   ```
   Use the latest reachable public Quill semver tag, such as `v0.1.0`, as the previous-release boundary. Ignore upstream FreeFlow-only tags when preparing Quill release notes. If tags are missing or inconsistent, fall back to the commit that introduced the prior `CHANGELOG.md` section or changed `CFBundleShortVersionString`/`CFBundleVersion`, and state that fallback explicitly.

3. Determine the next version:
   - `PATCH` for fixes, polish, release-system updates, and small user-visible improvements.
   - `MINOR` for notable new user-facing capabilities.
   - `MAJOR` only for breaking behavior or major compatibility changes.
   Confirm the version with the user if it was not specified.

4. Build and write the `CHANGELOG.md` entry from the previous release to the current release target:
   ```bash
   git log --first-parent --reverse --oneline <previous-release-tag>..HEAD
   git log --reverse --oneline <previous-release-tag>..HEAD
   git diff --stat <previous-release-tag>..HEAD
   git diff --name-status <previous-release-tag>..HEAD
   ```
   Prefer first-parent merge commits for feature grouping, then inspect individual commits and relevant diffs for details. Write a concise section near the top of `CHANGELOG.md`, above the previous release:
   ```md
   ## [0.1.1] - YYYY-MM-DD

   ### Added
   - User-facing new capabilities.

   ### Improved
   - User-facing improvements and reliability work.

   ### Fixed
   - User-visible bugs and update/release fixes.
   ```
   Include only categories that have entries. If the release contains mostly internal work, describe the user-facing effect, such as reliability, update behavior, packaging, or troubleshooting improvements. Do not include raw commit hashes in the changelog.

5. Validate locally before commit/release:
   ```bash
   .github/scripts/changelog-section.sh <version>
   .agents/skills/freeflow-release/scripts/freeflow-release-check.sh <version>
   git diff --check
   make clean
   make ARCH="$(uname -m)" CODESIGN_IDENTITY=- APP_VERSION=<version> BUILD_NUMBER=<build-number> BUILD_TAG=v<version>
   ```

6. Commit only release-prep files:
   ```bash
   git add CHANGELOG.md .github/workflows/manual-release.yml Tests/ManualReleaseWorkflowTests.swift Tests/BuildMetadataTests.swift Sources/SettingsView.swift
   git commit -m "Prepare v<version> release"
   ```
   Include other files only when they are deliberately part of the release prep.

7. After user approval, choose the release path:
   - Local signed release: build with the local `Quill` signing identity and create the GitHub Release with the verified local `Quill.dmg`.
   - Manual fallback release: run `.github/workflows/manual-release.yml` with `tag`, `build_number`, optional `release_name`, and optional `release_notes`.
   - Official notarized release: run `.github/workflows/release.yml` manually after Apple notarization secrets are configured.

8. After the release finishes, verify:
   - GitHub Release `v<version>` exists and is marked latest for stable releases.
   - `Quill.dmg` is attached.
   - The DMG app bundle has `CFBundleShortVersionString=<version>`, `CFBundleVersion=<build-number>`, and `QuillBuildTag=v<version>`.
   - Release body starts with the matching `CHANGELOG.md` section.

## Helper Script

Run `.agents/skills/freeflow-release/scripts/freeflow-release-check.sh <version>` from the Quill repo root to check release preconditions. It validates semver shape, required files, changelog extraction, workflow trigger basics, and tag availability.
