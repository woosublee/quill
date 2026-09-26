@main
struct FullSourceTranscriptionTestRunner {
    static func main() async throws {
        await CloudTranscriptionHistoryLifecycleTests.main()
        await TranscriptionServiceCloudChunkingTests.main()
        try await TranscriptionServiceLocalIssueTests.main()
        try await TranscriptionServiceLocalAITests.main()
        try PostProcessingUserIssueTests.main()
        try await PostProcessingBackendTests.main()
        try PostProcessingOutputValidatorTests.main()
        try PostProcessingChunkingTests.main()
        try await AppContextBackendTests.main()
        try MeetingSummaryOutputValidatorTests.main()
        try await MeetingSummaryServiceTests.main()
    }
}
