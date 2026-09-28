import Foundation

@main
struct UpdateManagerSafetyTests {
    static func main() throws {
        testReleaseBuildTagEligibility()
        testUpdateBuildComparison()
        try testUpdateManagerUsesSparkleFacade()
        try testUpdateManagerPersistsAvailableUpdate()
        try testUpdateManagerRemovedSelfInstallPipeline()
        try testSilentlyDownloadedUpdateOffersRestartInsteadOfSpinning()
        testInstallHandoffLifecycle()
        try testAppDelegateStartsPeriodicUpdateChecks()
        try testSettingsShowsUpdatesCard()
        try testTopLevelUpstreamAttributionIsHidden()
        print("UpdateManagerSafetyTests passed")
    }

    private static func testReleaseBuildTagEligibility() {
        precondition(UpdateManager.isReleaseBuildTagForAutomaticChecks("v0.1.0"))
        precondition(UpdateManager.isReleaseBuildTagForAutomaticChecks("v1.2.3-beta.1"))
        precondition(UpdateManager.isReleaseBuildTagForAutomaticChecks("V2.0.0+build.5"))

        precondition(!UpdateManager.isReleaseBuildTagForAutomaticChecks(nil))
        precondition(!UpdateManager.isReleaseBuildTagForAutomaticChecks("local-abc123"))
        precondition(!UpdateManager.isReleaseBuildTagForAutomaticChecks("dev-abc123"))
        precondition(!UpdateManager.isReleaseBuildTagForAutomaticChecks("0.1.0"))
        precondition(!UpdateManager.isReleaseBuildTagForAutomaticChecks("quill-v0.1.0"))
        precondition(!UpdateManager.isReleaseBuildTagForAutomaticChecks("v1.2"))
        precondition(!UpdateManager.isReleaseBuildTagForAutomaticChecks("v1.2.3-"))
    }

    private static func testUpdateBuildComparison() {
        precondition(UpdateManager.isCandidateBuildNewerForRestoration("32", than: "31"))
        precondition(UpdateManager.isCandidateBuildNewerForRestoration("1.10", than: "1.9"))
        precondition(!UpdateManager.isCandidateBuildNewerForRestoration("31", than: "31"))
        precondition(!UpdateManager.isCandidateBuildNewerForRestoration("30", than: "31"))
    }

    private static func testUpdateManagerUsesSparkleFacade() throws {
        let source = try String(contentsOfFile: "Sources/UpdateManager.swift", encoding: .utf8)

        assertContains(source, "import Sparkle")
        assertContains(source, "final class UpdateManager: NSObject, ObservableObject")
        assertContains(source, "SPUStandardUpdaterController(")
        assertContains(source, "startingUpdater: false")
        assertContains(source, "updaterDelegate: self")
        assertContains(source, "func startPeriodicChecks()")
        assertContains(source, "updaterController.startUpdater()")
        assertContains(source, "func checkForUpdates(userInitiated: Bool) async")
        assertContains(source, "updaterController.checkForUpdates(nil)")
        assertContains(source, "extension UpdateManager: SPUUpdaterDelegate")
        assertContains(source, "updateLastPostTranscriptionReminderVersion")
        assertContains(source, "updateLastPostTranscriptionReminderDate")
    }

    /// With automatic installation on, Sparkle downloads in the background and
    /// hands off an install-on-quit update. Quill must take that handoff and
    /// offer Restart to Update, not leave "Preparing update..." spinning (#411).
    /// Runs the install-on-quit handoff with a fake Sparkle handler: no
    /// network and no real updater (#411).
    private static func testInstallHandoffLifecycle() {
        // Quill takes control so it can offer Restart to Update.
        precondition(UpdateInstallHandoff.takesControlOfInstallOnQuit)

        var handoff = UpdateInstallHandoff()
        precondition(!handoff.isPending)
        precondition(!handoff.installNow(), "Nothing to install before the handoff")

        var installCalls = 0
        handoff.receive { installCalls += 1 }
        precondition(handoff.isPending)

        // Restart to Update runs Sparkle's handler.
        precondition(handoff.installNow())
        precondition(installCalls == 1)
        // A canceled quit (for example during a recording) keeps it usable.
        precondition(handoff.isPending)
        precondition(handoff.installNow())
        precondition(installCalls == 2)

        // A failed cycle drops it, so later checks start a fresh cycle.
        handoff.clear()
        precondition(!handoff.isPending)
        precondition(!handoff.installNow())
        precondition(installCalls == 2)
    }

    private static func testSilentlyDownloadedUpdateOffersRestartInsteadOfSpinning() throws {
        let source = try String(contentsOfFile: "Sources/UpdateManager.swift", encoding: .utf8)
        assertContains(source, "case readyToInstall")
        assertContains(source, "willInstallUpdateOnQuit item: SUAppcastItem,")
        assertContains(source, "immediateInstallationBlock immediateInstallHandler: @escaping () -> Void")
        assertContains(source, "installHandoff.receive(immediateInstallHandler)")
        assertContains(source, "return UpdateInstallHandoff.takesControlOfInstallOnQuit")
        // Failures drop the handoff; "What's New" never installs.
        assertContains(source, "func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {\n        installHandoff.clear()")
        assertContains(source, "} else if !hasPendingInstall {")
        assertContains(source, "updateStatus = .readyToInstall")
        assertContains(source, "func installReadyUpdateNow()")
        // Canceling the quit prompt must keep Restart to Update available:
        // only Sparkle's relaunch callback changes the status.
        let install = source.components(separatedBy: "func installReadyUpdateNow() {")[1]
            .components(separatedBy: "\n    }")[0]
        precondition(!install.contains("updateStatus ="), "installReadyUpdateNow must not change the status itself")
        // A manual check while an update waits installs it instead of doing nothing.
        assertContains(source, "if userInitiated, hasPendingInstall {\n            installReadyUpdateNow()")
        // The after-transcription reminder also covers a waiting update.
        assertContains(source, "updateStatus == .idle || updateStatus == .readyToInstall")
        let appState = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)
        assertContains(appState, "if UpdateManager.shared.hasPendingInstall {\n                // Already downloaded and verified: restart to install it.\n                UpdateManager.shared.installReadyUpdateNow()")
        // A found update also counts as a check, so "Last checked" moves on.
        assertContains(source, "applyAvailableUpdate(item)\n        lastCheckDate = Date()")

        let settings = try String(contentsOfFile: "Sources/SettingsView.swift", encoding: .utf8)
        assertContains(settings, "case .readyToInstall:")
        assertContains(settings, "updateManager.installReadyUpdateNow()")
        let menuBar = try String(contentsOfFile: "Sources/MenuBarView.swift", encoding: .utf8)
        assertContains(menuBar, "case .readyToInstall:")
        assertContains(menuBar, "updateManager.installReadyUpdateNow()")
    }

    private static func testUpdateManagerPersistsAvailableUpdate() throws {
        let source = try String(contentsOfFile: "Sources/UpdateManager.swift", encoding: .utf8)

        assertContains(source, "UpdateSnapshotStore(userDefaults: .standard)")
        assertContains(source, "restorePersistedUpdateIfAvailable()")
        assertContains(source, "item.versionString")
        assertContains(source, "SUSkippedVersion")
        assertContains(source, "SUSkippedMajorVersion")
        assertContains(source, "SUSkippedMajorSubreleaseVersion")
        assertContains(source, "guard Self.isReleaseBuildTagForAutomaticChecks(currentBuildTag) else { return }")
        assertContains(source, "SUStandardVersionComparator.default")
        assertContains(source, "updateSnapshotStore.save(snapshot)")
        assertContains(source, "updateSnapshotStore.clear()")
        assertContains(source, "case .skip:")

        let noUpdateCallback = extract(
            source,
            from: "func updaterDidNotFindUpdate",
            to: "func updater(_ updater: SPUUpdater, userDidMake"
        )
        let abortCallback = extract(
            source,
            from: "func updater(_ updater: SPUUpdater, didAbortWithError",
            to: "func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor"
        )
        assertContains(noUpdateCallback, "clearAvailableUpdate()")
        assertDoesNotContain(abortCallback, "clearAvailableUpdate()")
        assertContains(
            source,
            "if nsError.domain == SUSparkleErrorDomain, nsError.code == SUError.noUpdateError.rawValue {\n                clearAvailableUpdate()\n            } else {"
        )
        // Any other failure drops a stored install handoff and shows the error.
        assertContains(
            source,
            "installHandoff.clear()\n                if updateStatus == .idle || updateStatus == .readyToInstall {"
        )
    }

    private static func testUpdateManagerRemovedSelfInstallPipeline() throws {
        let source = try String(contentsOfFile: "Sources/UpdateManager.swift", encoding: .utf8)

        assertDoesNotContain(source, "https://api.github.com/repos/woosublee/quill/releases")
        assertDoesNotContain(source, "struct GitHubRelease")
        assertDoesNotContain(source, "struct GitHubReleaseAsset")
        assertDoesNotContain(source, "installableDMGAsset")
        assertDoesNotContain(source, "validateDownloadedDMG")
        assertDoesNotContain(source, "validateStagedApp")
        assertDoesNotContain(source, "temporarySelfSignedQuillFallbackRequirement")
        assertDoesNotContain(source, "hdiutil")
        assertDoesNotContain(source, "mountDMG")
        assertDoesNotContain(source, "replaceAndRelaunch")
        assertDoesNotContain(source, "/bin/bash")
        assertDoesNotContain(source, "URLSession.shared.bytes")
        assertDoesNotContain(source, "downloadAndInstall")
    }

    private static func testAppDelegateStartsPeriodicUpdateChecks() throws {
        let source = try String(contentsOfFile: "Sources/AppDelegate.swift", encoding: .utf8)
        let activeLines = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        let activeCallCount = activeLines.filter {
            $0.contains("UpdateManager.shared.startPeriodicChecks()")
        }.count

        // Normal relaunch and finishing setup share one post-setup
        // initializer, so this call now has a single active site.
        precondition(activeCallCount == 1, "Expected exactly 1 active periodic update check call")
        precondition(
            !source.contains("Quill releases are not distributed through the in-app updater yet."),
            "Expected obsolete in-app updater disabled message to be removed"
        )
    }

    private static func testSettingsShowsUpdatesCard() throws {
        let source = try String(contentsOfFile: "Sources/SettingsView.swift", encoding: .utf8)
        let activeText = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        assertContains(activeText, "SettingsCard(\"Updates\", icon: \"arrow.triangle.2.circlepath\")")
        assertContains(activeText, "updatesSection")
        assertContains(source, "Automatically check for updates")
        assertContains(source, "Check for Updates Now")
        // Implementation detail, not user information.
        assertDoesNotContain(source, "Updates are delivered by Sparkle")
        assertContains(source, "Update Now")
        assertContains(source, "updateManager.showUpdateAlert()")
        assertDoesNotContain(source, "downloadAndInstall(release: release)")
    }

    private static func testTopLevelUpstreamAttributionIsHidden() throws {
        let setupView = try String(contentsOfFile: "Sources/SetupView.swift", encoding: .utf8)
        let settingsView = try String(contentsOfFile: "Sources/SettingsView.swift", encoding: .utf8)

        let setupWelcomeStep = extract(setupView, from: "var welcomeStep: some View", to: "var processingStep: some View")
        let settingsHeader = extract(
            settingsView,
            from: "Image(nsImage: NSApp.applicationIconImage)",
            to: "SettingsCard(\"Build\", icon: \"info.circle.fill\")"
        )

        assertDoesNotContain(setupWelcomeStep, "zachlatta/freeflow")
        assertDoesNotContain(setupWelcomeStep, "contributors")
        assertDoesNotContain(settingsHeader, "zachlatta/freeflow")
        assertDoesNotContain(settingsHeader, "starred")
        assertDoesNotContain(settingsView, "githubCache.fetchIfNeeded(")
    }

    private static func extract(_ text: String, from startMarker: String, to endMarker: String) -> String {
        guard let start = text.range(of: startMarker) else {
            preconditionFailure("Missing start marker: \(startMarker)")
        }
        guard let end = text[start.lowerBound...].range(of: endMarker) else {
            preconditionFailure("Missing end marker: \(endMarker)")
        }
        return String(text[start.lowerBound..<end.lowerBound])
    }

    private static func assertContains(_ text: String, _ expected: String) {
        precondition(text.contains(expected), "Expected content to contain \(expected)")
    }

    private static func assertDoesNotContain(_ text: String, _ unexpected: String) {
        precondition(!text.contains(unexpected), "Expected content not to contain \(unexpected)")
    }
}
