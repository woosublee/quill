import Foundation

@main
struct FullSourceAppStateTestRunner {
    private static let isolatedChildArgument = "--quill-app-state-isolated-child"
    private static let isolatedRootEnvironmentKey = "QUILL_APP_STATE_TEST_ISOLATION_ROOT"

    static func main() async throws {
        if !isValidIsolatedChildEnvironment() {
            try runInIsolatedProcess()
            return
        }

        try await AppStateTestStorage.withIsolatedStorage { _ in
            try AppStateDependenciesTests.main()
            try await NoteAssetStoreTests.main()
            try CredentialStoreTests.main()
            try await AudioImportFileCopyTests.main()
            try LatestValueProgressCoalescerTests.main()
            try await HistoryArchiveRecoveryWorkflowTests.main()
            try await TranscriptionRetryWorkflowTests.main()
            try await NativeWhisperModelWorkflowTests.main()
            try await LocalAIModelWorkflowTests.main()
            try await AppStateStorageSafetyTests.main()
            try await CombinedCaptureDegradationTests.main()
            try AppStateHistoryProtectionSourceTests.main()
            try await AppStateTranscriptionConfigurationTests.main()
            try await AppStateAIProcessingBackendTests.main()
            try await MeetingSummaryWorkflowTests.main()
            try await MeetingSummaryAppStateTests.main()
            try await AppStateNoteSyncTests.main()
        }
    }

    private static func isValidIsolatedChildEnvironment() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard CommandLine.arguments.contains(isolatedChildArgument),
              let rootPath = environment[isolatedRootEnvironmentKey],
              let userHomePath = environment["CFFIXED_USER_HOME"],
              let temporaryDirectoryPath = environment["TMPDIR"] else {
            return false
        }

        let rootDirectory = URL(fileURLWithPath: rootPath).standardizedFileURL
        guard rootDirectory.lastPathComponent.hasPrefix("quill-app-state-runner-") else {
            return false
        }
        let expectedTemporaryDirectory = rootDirectory
            .appendingPathComponent("tmp")
            .standardizedFileURL
        return URL(fileURLWithPath: userHomePath).standardizedFileURL == rootDirectory
            && URL(fileURLWithPath: temporaryDirectoryPath).standardizedFileURL == expectedTemporaryDirectory
            && FileManager.default.fileExists(atPath: expectedTemporaryDirectory.path)
    }

    private static func runInIsolatedProcess() throws {
        let isolatedHome = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "quill-app-state-runner-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: isolatedHome) }
        try FileManager.default.createDirectory(
            at: isolatedHome.appendingPathComponent("tmp", isDirectory: true),
            withIntermediateDirectories: true
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = Array(CommandLine.arguments.dropFirst()) + [isolatedChildArgument]
        var environment = ProcessInfo.processInfo.environment
        environment[isolatedRootEnvironmentKey] = isolatedHome.path
        environment["CFFIXED_USER_HOME"] = isolatedHome.path
        environment["TMPDIR"] = isolatedHome.appendingPathComponent("tmp").path
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw TestRunnerFailure(status: process.terminationStatus)
        }
    }

    private struct TestRunnerFailure: Error, CustomStringConvertible {
        let status: Int32

        var description: String {
            "FullSourceAppStateTestRunner child failed with status \(status)"
        }
    }
}
