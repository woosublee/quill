# Task 4 Report — LocalAIInstaller

## RED / GREEN
- RED: `swiftc -parse-as-library Sources/LocalizedStringLookup.swift Sources/LocalAIModel.swift Tests/LocalAIInstallerTests.swift -o /tmp/LocalAIInstallerTests && /tmp/LocalAIInstallerTests` failed as intended because `LocalAIInstaller` and `LocalAIInstallerError` did not exist.
- GREEN: the focused compiler/test command including `Sources/LocalAIInstaller.swift` passes with `LocalAIInstallerTests passed`.

## Behavior delivered
- A model package downloads its artifacts sequentially, while the install queue remains concurrent across different models.
- Progress is aggregated at package scope, with the final update equal to `model.approximateBytes`.
- In-flight de-duplication covers the whole package and includes both the store root and model ID.

## Failure cleanup and rollback evidence
- Download failure, validation failure, and cancellation remove every selected package partial before completion and leave existing finals unchanged.
- All partial artifacts are validated before any existing final is replaced.
- Package commits move prior finals to temporary backups first. The simulated second replacement failure test verifies that every prior final is restored and no `.backup-*` or `.download` files remain.

## Verification
- Focused installer test: passed.
- `make check-test-wiring && make test-transcription`: passed. The existing CoreData duplicate entity-description warnings were emitted, but the command exited successfully and all tests, including `LocalAIInstallerTests`, passed.

## Self-review
- Reviewed the diff with `git diff --check`; no whitespace errors.
- Scope is limited to the installer, its focused tests, and transcription test wiring; no ServerProcess work was changed.
- The filesystem seam is intentionally small and only controls package commit operations for the rollback test.

## Commit
- `Add multi-artifact LocalAIInstaller`

## Concerns
- No blocking concerns. The injected downloader is synchronous by contract, so cancellation of a custom downloader depends on that downloader observing `LocalAIInstallTask`; the built-in URLSession downloader installs a cancellation handler for its active request.

## Review Fix Report
- Added cancellation checks around every validation, immediately before package commit, before and after every artifact installation, and at the final pre-commit boundary. A cancellation observed while committing rolls the package back and returns `.cancelled` when rollback succeeds.
- Wrapped each installer-side injected download call in `defer { task.setCancellationHandler(nil) }`, preventing a completed or failed artifact from retaining a stale cancellation handler.
- Reworked package commit lifecycle: commit failures invoke recovery without deleting backups before each final is restored; failed recovery preserves any still-needed backups and reports recovery detail. Backup deletion now runs only after a successful commit as best-effort cleanup, so cleanup failure preserves the new valid package (and may retain backups for later cleanup).
- Corrected the simulated move failure to use `(source, destination)` and asserted it occurs at the second artifact installation.
- Added deterministic coverage for cancellation during validation, cancellation after the second artifact is installed, stale downloader-handler cleanup, actual second-install failure rollback, and backup-cleanup failure preserving the new package.

### Review Fix Verification
- `swiftc -parse-as-library Sources/LocalizedStringLookup.swift Sources/LocalAIModel.swift Sources/LocalAIInstaller.swift Tests/LocalAIInstallerTests.swift -o /tmp/LocalAIInstallerTests && /tmp/LocalAIInstallerTests`: passed.
- `make check-test-wiring && make test-transcription`: passed. Existing CoreData duplicate entity-description warnings were emitted; all test commands exited successfully.
