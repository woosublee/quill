@main
struct FullSourceTranscriptionTestRunner {
    static func main() async throws {
        await CloudTranscriptionHistoryLifecycleTests.main()
        await TranscriptionServiceCloudChunkingTests.main()
        try await TranscriptionServiceLocalIssueTests.main()
        try PostProcessingUserIssueTests.main()
    }
}
