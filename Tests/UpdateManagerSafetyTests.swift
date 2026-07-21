import Foundation

@main
struct UpdateManagerSafetyTests {
    static func main() throws {
        testReleaseBuildTagEligibility()
        try testUpdateManagerUsesSparkleFacade()
        try testUpdateManagerRemovedSelfInstallPipeline()
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

        precondition(activeCallCount == 2, "Expected exactly 2 active periodic update check calls")
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
        assertContains(source, "Updates are delivered by Sparkle")
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
