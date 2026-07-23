@main
struct FullSourceAppStateTestRunner {
    static func main() async throws {
        try await AudioImportFileCopyTests.main()
        try LatestValueProgressCoalescerTests.main()
        try await AppStateTranscriptionConfigurationTests.main()
        try await AppStateAIProcessingBackendTests.main()
    }
}
