@main
struct FullSourceTranscriptionTestRunner {
    static func main() async throws {
        try AppleSpeechEngineSelectionTests.main()
        try AppleSpeechUtteranceTranscriptTests.main()
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
        try MeetingSummaryEditingTests.main()
        try await MeetingSummaryServiceTests.main()
    }
}
