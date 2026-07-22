@main
struct FullSourceAppStateTestRunner {
    static func main() async throws {
        try await AudioImportFileCopyTests.main()
        try await AppStateTranscriptionConfigurationTests.main()
        try await AppStateAIProcessingBackendTests.main()
    }
}
