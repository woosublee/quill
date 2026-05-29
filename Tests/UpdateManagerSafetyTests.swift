import Foundation

@main
struct UpdateManagerSafetyTests {
    static func main() throws {
        testInstallableAssetSelection()
        testReleaseBuildTagEligibility()
        try testTimingPoliciesRemainConservative()
        try testDownloadedDMGValidationAcceptsGatekeeperPath()
        try testDownloadedDMGValidationUsesTemporarySelfSignedFallbackForAllowlistedQuillDMG()
        try testDownloadedDMGValidationRejectsNonAllowlistedGatekeeperFailure()
        testTemporarySelfSignedFallbackRequirementAllowsKnownQuillCertificateLeaves()
        try testValidationCommandDrainsPipesBeforeWaiting()
        try testStagedAppValidationChecksMetadataAndCodesign()
        try testStagedAppValidationRejectsMetadataMismatch()
        try testStagedAppValidationRejectsSignerMismatch()
        try testInstallFlowValidatesBeforeReplacing()
        try testTemporarySelfSignedFallbackRemainsStagedAppGated()
        try testStagedAppValidationRejectsNonAppBeforeCodesign()
        try testMountDMGDoesNotDisableVerification()
        try testAppDelegateStartsPeriodicUpdateChecks()
        try testSettingsShowsUpdatesCard()
        try testRecentReleaseWaitPreservesAvailableUpdate()
        try testTopLevelUpstreamAttributionIsHidden()
        print("UpdateManagerSafetyTests passed")
    }

    private static func testInstallableAssetSelection() {
        let expectedAsset = asset(named: "Quill.dmg")
        let releaseWithQuillAsset = release(assets: [
            asset(named: "Quill-Dev.dmg"),
            expectedAsset,
            asset(named: "Quill-Unsigned.dmg"),
            asset(named: "FreeFlow.dmg")
        ])

        let selectedAsset = UpdateManager.installableDMGAsset(for: releaseWithQuillAsset)
        precondition(selectedAsset?.name == "Quill.dmg", "Expected Quill.dmg to be selected")
        precondition(selectedAsset?.browserDownloadUrl == expectedAsset.browserDownloadUrl, "Expected the exact Quill.dmg asset")

        precondition(UpdateManager.installableDMGAsset(for: release(assets: [asset(named: "Quill-Dev.dmg")])) == nil)
        precondition(UpdateManager.installableDMGAsset(for: release(assets: [asset(named: "Quill-Unsigned.dmg")])) == nil)
        precondition(UpdateManager.installableDMGAsset(for: release(assets: [asset(named: "FreeFlow.dmg")])) == nil)
        precondition(UpdateManager.installableDMGAsset(for: release(assets: [asset(named: "Quill.zip")])) == nil)
        precondition(UpdateManager.installableDMGAsset(for: release(assets: [])) == nil)
    }

    private static func testReleaseBuildTagEligibility() {
        precondition(UpdateManager.isReleaseBuildTagForAutomaticChecks("v0.1.0"))
        precondition(UpdateManager.isReleaseBuildTagForAutomaticChecks("v1.2.3-beta.1"))

        precondition(!UpdateManager.isReleaseBuildTagForAutomaticChecks(nil))
        precondition(!UpdateManager.isReleaseBuildTagForAutomaticChecks("local-abc123"))
        precondition(!UpdateManager.isReleaseBuildTagForAutomaticChecks("dev-abc123"))
        precondition(!UpdateManager.isReleaseBuildTagForAutomaticChecks("0.1.0"))
        precondition(!UpdateManager.isReleaseBuildTagForAutomaticChecks("quill-v0.1.0"))
    }

    private static func testTimingPoliciesRemainConservative() throws {
        let source = try String(contentsOfFile: "Sources/UpdateManager.swift", encoding: .utf8)

        assertContains(source, "private let stabilityBufferDays: TimeInterval = 3")
        assertContains(source, "private let checkIntervalSeconds: TimeInterval = 7 * 24 * 60 * 60")
    }

    private static func testDownloadedDMGValidationAcceptsGatekeeperPath() throws {
        let dmgURL = URL(fileURLWithPath: "/tmp/Quill.dmg")
        var recordedExecutablePath: String?
        var recordedArguments: [String]?

        let trustPath = try UpdateManager.validateDownloadedDMG(at: dmgURL) { executablePath, arguments in
            recordedExecutablePath = executablePath
            recordedArguments = arguments
            return UpdateValidationCommandResult(terminationStatus: 0, standardOutput: "accepted", standardError: "")
        }

        precondition(trustPath == .gatekeeperAccepted, "Expected Gatekeeper accepted DMG trust path")
        precondition(recordedExecutablePath == "/usr/sbin/spctl", "Expected spctl to assess downloaded DMG")
        precondition(recordedArguments == [
            "--assess",
            "--type", "open",
            "--context", "context:primary-signature",
            "--verbose=4",
            dmgURL.path
        ], "Expected spctl assessment arguments")
    }

    private static func testDownloadedDMGValidationUsesTemporarySelfSignedFallbackForAllowlistedQuillDMG() throws {
        let dmgURL = URL(fileURLWithPath: "/tmp/Quill.dmg")
        var commands: [(String, [String])] = []

        let trustPath = try UpdateManager.validateDownloadedDMG(at: dmgURL) { executablePath, arguments in
            commands.append((executablePath, arguments))
            if executablePath == "/usr/sbin/spctl" {
                return UpdateValidationCommandResult(terminationStatus: 3, standardOutput: "", standardError: "rejected")
            }
            if executablePath == "/usr/bin/codesign", arguments.contains("--verify") {
                return UpdateValidationCommandResult(terminationStatus: 0, standardOutput: "valid", standardError: "")
            }
            if executablePath == "/usr/bin/codesign", arguments == ["-d", "-r-", dmgURL.path] {
                return UpdateValidationCommandResult(
                    terminationStatus: 0,
                    standardOutput: "",
                    standardError: "designated => identifier \"Quill\" and certificate leaf = H\"7172dcfff89f1a17f40fd14bac80f975536c97ed\""
                )
            }
            preconditionFailure("Unexpected command: \(executablePath) \(arguments)")
        }

        guard case let .temporarySelfSignedQuillFallback(reason) = trustPath else {
            preconditionFailure("Expected temporary self-signed Quill fallback after allowlisted Gatekeeper rejection")
        }

        precondition(reason.contains("spctl assessment failed with exit code 3"))
        precondition(reason.contains("rejected"))
        precondition(commands.map(\.0) == ["/usr/sbin/spctl", "/usr/bin/codesign", "/usr/bin/codesign"])
    }

    private static func testDownloadedDMGValidationRejectsNonAllowlistedGatekeeperFailure() throws {
        let dmgURL = URL(fileURLWithPath: "/tmp/Quill.dmg")

        assertThrows {
            try UpdateManager.validateDownloadedDMG(at: dmgURL) { executablePath, arguments in
                if executablePath == "/usr/sbin/spctl" {
                    return UpdateValidationCommandResult(terminationStatus: 3, standardOutput: "", standardError: "rejected")
                }
                if executablePath == "/usr/bin/codesign", arguments.contains("--verify") {
                    return UpdateValidationCommandResult(terminationStatus: 1, standardOutput: "", standardError: "unsigned")
                }
                preconditionFailure("Unexpected command: \(executablePath) \(arguments)")
            }
        }
    }

    private static func testTemporarySelfSignedFallbackRequirementAllowsKnownQuillCertificateLeaves() {
        let currentRequirement = "identifier \"com.woosublee.quill\" and certificate leaf = H\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\""
        let requirement = UpdateManager.temporarySelfSignedQuillFallbackRequirement(
            currentRequirement: currentRequirement,
            expectedBundleIdentifier: "com.woosublee.quill"
        )

        assertContains(requirement, "(\(currentRequirement))")
        assertContains(requirement, "identifier \"com.woosublee.quill\"")
        assertContains(requirement, ") or (")

        let pinnedLeaves = certificateLeaves(in: requirement)
        precondition(
            Set(pinnedLeaves) == Set([
                "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                "7172DCFFF89F1A17F40FD14BAC80F975536C97ED"
            ]),
            "Expected exact pinned leaf set for temporary self-signed fallback requirement"
        )
    }

    private static func testValidationCommandDrainsPipesBeforeWaiting() throws {
        let source = try String(contentsOfFile: "Sources/UpdateManager.swift", encoding: .utf8)
        let methodSource = extract(
            source,
            from: "nonisolated static func runValidationCommand(",
            to: "nonisolated static func validateDownloadedDMG("
        )

        assertOrdered(
            methodSource,
            "outputPipe.fileHandleForReading.readDataToEndOfFile()",
            before: "process.waitUntilExit()",
            message: "Expected stdout to be drained before waiting for the process"
        )
        assertOrdered(
            methodSource,
            "errorPipe.fileHandleForReading.readDataToEndOfFile()",
            before: "process.waitUntilExit()",
            message: "Expected stderr to be drained before waiting for the process"
        )
    }

    private static func testStagedAppValidationChecksMetadataAndCodesign() throws {
        let appURL = try makeTemporaryApp(
            bundleIdentifier: "com.classmethod.Quill",
            shortVersion: "1.2.3",
            buildTag: "v1.2.3"
        )
        var recordedExecutablePath: String?
        var recordedArguments: [String]?

        let expectedRequirement = "identifier \"com.classmethod.Quill\" and anchor apple generic"
        try UpdateManager.validateStagedApp(
            at: appURL,
            expectedBundleIdentifier: "com.classmethod.Quill",
            expectedShortVersion: "1.2.3",
            expectedBuildTag: "v1.2.3",
            expectedRequirement: expectedRequirement
        ) { executablePath, arguments in
            recordedExecutablePath = executablePath
            recordedArguments = arguments
            return UpdateValidationCommandResult(terminationStatus: 0, standardOutput: "valid", standardError: "")
        }

        precondition(recordedExecutablePath == "/usr/bin/codesign", "Expected codesign to verify staged app")
        precondition(recordedArguments == [
            "--verify",
            "--deep",
            "--strict",
            "--verbose=2",
            "-R=\(expectedRequirement)",
            appURL.path
        ], "Expected codesign verification arguments")
    }

    private static func testStagedAppValidationRejectsMetadataMismatch() throws {
        let appURL = try makeTemporaryApp(
            bundleIdentifier: "com.classmethod.Quill",
            shortVersion: "1.2.3",
            buildTag: "v1.2.3"
        )
        var didRunCodesign = false

        assertThrows {
            try UpdateManager.validateStagedApp(
                at: appURL,
                expectedBundleIdentifier: "com.classmethod.Quill",
                expectedShortVersion: "1.2.4",
                expectedBuildTag: "v1.2.3",
                expectedRequirement: "identifier \"com.classmethod.Quill\" and anchor apple generic"
            ) { _, _ in
                didRunCodesign = true
                return UpdateValidationCommandResult(terminationStatus: 0, standardOutput: "valid", standardError: "")
            }
        }

        precondition(!didRunCodesign, "Expected metadata mismatch to fail before codesign")
    }

    private static func testStagedAppValidationRejectsSignerMismatch() throws {
        let appURL = try makeTemporaryApp(
            bundleIdentifier: "com.classmethod.Quill",
            shortVersion: "1.2.3",
            buildTag: "v1.2.3"
        )

        assertThrows {
            try UpdateManager.validateStagedApp(
                at: appURL,
                expectedBundleIdentifier: "com.classmethod.Quill",
                expectedShortVersion: "1.2.3",
                expectedBuildTag: "v1.2.3",
                expectedRequirement: "identifier \"com.classmethod.Quill\" and anchor apple generic"
            ) { _, _ in
                UpdateValidationCommandResult(terminationStatus: 1, standardOutput: "", standardError: "explicit requirement failed")
            }
        }
    }

    private static func testInstallFlowValidatesBeforeReplacing() throws {
        let source = try String(contentsOfFile: "Sources/UpdateManager.swift", encoding: .utf8)

        assertContains(source, "private func performUpdate(downloadURL: URL, expectedSize: Int, release: GitHubRelease) async")
        let performUpdateSource = extract(
            source,
            from: "private func performUpdate(downloadURL: URL, expectedSize: Int, release: GitHubRelease) async",
            to: "nonisolated private func mountDMG"
        )
        assertOrdered(
            performUpdateSource,
            "currentAppRequirement()",
            before: "validateStagedApp(",
            message: "Expected current app signer requirement before staged app validation"
        )
        assertOrdered(
            performUpdateSource,
            "validateDownloadedDMG(at: dmgPath)",
            before: "mountDMG(at: dmgPath)",
            message: "Expected downloaded DMG validation before mounting"
        )
        assertOrdered(
            performUpdateSource,
            "validateStagedApp(",
            before: "replaceAndRelaunch(stagedApp: stagedApp, stagingDir: stagingDir)",
            message: "Expected staged app validation before replacement"
        )
        assertContains(source, "performUpdate(downloadURL: downloadURL, expectedSize: dmgAsset.size, release: release)")
    }

    private static func testTemporarySelfSignedFallbackRemainsStagedAppGated() throws {
        let source = try String(contentsOfFile: "Sources/UpdateManager.swift", encoding: .utf8)
        assertContains(source, "case temporarySelfSignedQuillFallback(String)")

        let performUpdateSource = extract(
            source,
            from: "private func performUpdate(downloadURL: URL, expectedSize: Int, release: GitHubRelease) async",
            to: "nonisolated private func mountDMG"
        )

        assertOrdered(
            performUpdateSource,
            "validateDownloadedDMG(at: dmgPath)",
            before: "mountDMG(at: dmgPath)",
            message: "Expected downloaded DMG trust path selection before mounting"
        )
        assertOrdered(
            performUpdateSource,
            "currentAppRequirement()",
            before: "temporarySelfSignedQuillFallbackRequirement(",
            message: "Expected current app signing requirement before temporary self-signed fallback allowlist expansion"
        )
        assertOrdered(
            performUpdateSource,
            "temporarySelfSignedQuillFallbackRequirement(",
            before: "validateStagedApp(",
            message: "Expected temporary self-signed fallback allowlist before staged app validation"
        )
        assertOrdered(
            performUpdateSource,
            "validateStagedApp(",
            before: "replaceAndRelaunch(stagedApp: stagedApp, stagingDir: stagingDir)",
            message: "Expected temporary self-signed fallback to remain gated by staged app validation"
        )
    }

    private static func testStagedAppValidationRejectsNonAppBeforeCodesign() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Quill-")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let contentsURL = directoryURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        let infoPlist: [String: Any] = [
            "CFBundleIdentifier": "com.classmethod.Quill",
            "CFBundleShortVersionString": "1.2.3",
            "QuillBuildTag": "v1.2.3"
        ]
        let infoPlistData = try PropertyListSerialization.data(fromPropertyList: infoPlist, format: .xml, options: 0)
        try infoPlistData.write(to: contentsURL.appendingPathComponent("Info.plist"))
        var didRunCodesign = false

        assertThrows {
            try UpdateManager.validateStagedApp(
                at: directoryURL,
                expectedBundleIdentifier: "com.classmethod.Quill",
                expectedShortVersion: "1.2.3",
                expectedBuildTag: "v1.2.3",
                expectedRequirement: "identifier \"com.classmethod.Quill\" and anchor apple generic"
            ) { _, _ in
                didRunCodesign = true
                return UpdateValidationCommandResult(terminationStatus: 0, standardOutput: "valid", standardError: "")
            }
        }

        precondition(!didRunCodesign, "Expected non-.app path to fail before codesign")
    }

    private static func testMountDMGDoesNotDisableVerification() throws {
        let source = try String(contentsOfFile: "Sources/UpdateManager.swift", encoding: .utf8)
        precondition(!source.contains("\"-noverify\""), "DMG mounting must not disable verification")
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
        assertContains(source, "Update Now")
        assertContains(source, "downloadAndInstall(release: release)")
    }

    private static func testRecentReleaseWaitPreservesAvailableUpdate() throws {
        let source = try String(contentsOfFile: "Sources/UpdateManager.swift", encoding: .utf8)
        guard let methodRange = source.range(of: "private func showRecentReleaseAlert(daysSincePublished: Double)") else {
            preconditionFailure("Expected showRecentReleaseAlert implementation")
        }
        let methodSource = String(source[methodRange.lowerBound...])
        let endRange = methodSource.range(of: "\n    func showUpToDateAlert()")
        let recentReleaseAlert = endRange.map { String(methodSource[..<$0.lowerBound]) } ?? methodSource

        assertDoesNotContain(recentReleaseAlert, "updateAvailable = false")
    }

    private static func testTopLevelUpstreamAttributionIsHidden() throws {
        let setupView = try String(contentsOfFile: "Sources/SetupView.swift", encoding: .utf8)
        let settingsView = try String(contentsOfFile: "Sources/SettingsView.swift", encoding: .utf8)

        let setupWelcomeStep = extract(setupView, from: "var welcomeStep: some View", to: "var apiKeyStep: some View")
        let settingsHeader = extract(
            settingsView,
            from: "Image(nsImage: NSApp.applicationIconImage)",
            to: "SettingsCard(\"App\", icon: \"power\")"
        )

        assertDoesNotContain(setupWelcomeStep, "zachlatta/freeflow")
        assertDoesNotContain(setupWelcomeStep, "contributors")
        assertDoesNotContain(settingsHeader, "zachlatta/freeflow")
        assertDoesNotContain(settingsHeader, "starred")
        assertDoesNotContain(settingsView, "githubCache.fetchIfNeeded(")
    }

    private static func asset(named name: String) -> GitHubReleaseAsset {
        GitHubReleaseAsset(
            name: name,
            browserDownloadUrl: "https://example.com/\(name)",
            size: 123
        )
    }

    private static func release(assets: [GitHubReleaseAsset]) -> GitHubRelease {
        GitHubRelease(
            tagName: "v0.1.0",
            name: "Quill v0.1.0",
            body: nil,
            htmlUrl: "https://example.com/releases/v0.1.0",
            publishedAt: "2026-05-20T00:00:00Z",
            assets: assets
        )
    }

    private static func makeTemporaryApp(
        bundleIdentifier: String,
        shortVersion: String,
        buildTag: String
    ) throws -> URL {
        let appURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Quill-\(UUID().uuidString)")
            .appendingPathExtension("app")
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)

        let infoPlist: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleShortVersionString": shortVersion,
            "QuillBuildTag": buildTag
        ]
        let infoPlistData = try PropertyListSerialization.data(fromPropertyList: infoPlist, format: .xml, options: 0)
        try infoPlistData.write(to: contentsURL.appendingPathComponent("Info.plist"))

        return appURL
    }

    private static func assertContains(_ text: String, _ expected: String) {
        precondition(text.contains(expected), "Expected source to contain \(expected)")
    }

    private static func extract(_ text: String, from start: String, to end: String) -> String {
        guard let startRange = text.range(of: start) else {
            preconditionFailure("Expected source to contain start marker \(start)")
        }
        guard let endRange = text[startRange.upperBound...].range(of: end) else {
            preconditionFailure("Expected source to contain end marker \(end)")
        }
        return String(text[startRange.lowerBound..<endRange.lowerBound])
    }

    private static func assertDoesNotContain(_ text: String, _ unexpected: String) {
        precondition(!text.contains(unexpected), "Expected source not to contain \(unexpected)")
    }

    private static func certificateLeaves(in requirement: String) -> [String] {
        let pattern = #"certificate leaf = H\"([0-9A-Fa-f]{40})\""#
        let regex = try! NSRegularExpression(pattern: pattern)
        let nsRequirement = requirement as NSString
        return regex
            .matches(in: requirement, range: NSRange(location: 0, length: nsRequirement.length))
            .compactMap { match -> String? in
                guard match.numberOfRanges > 1 else { return nil }
                return nsRequirement.substring(with: match.range(at: 1)).uppercased()
            }
    }

    private static func assertOrdered(_ text: String, _ earlier: String, before later: String, message: String) {
        guard let earlierRange = text.range(of: earlier) else {
            preconditionFailure("Expected source to contain \(earlier)")
        }
        guard let laterRange = text.range(of: later) else {
            preconditionFailure("Expected source to contain \(later)")
        }
        precondition(earlierRange.lowerBound < laterRange.lowerBound, message)
    }

    private static func assertThrows(_ operation: () throws -> Void) {
        do {
            try operation()
            preconditionFailure("Expected operation to throw")
        } catch {
            return
        }
    }
}
