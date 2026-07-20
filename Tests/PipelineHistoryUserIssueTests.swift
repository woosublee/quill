import Foundation

@main
struct PipelineHistoryUserIssueTests {
    static func main() throws {
        let bundle = try compiledLocalizationBundle()
        try testVersionedErrorBecomesFailedMachineStatus(bundle: bundle)
        try testVersionedWarningRemainsCompleted(bundle: bundle)
        try testLegacyErrorUsesGenericSafePresentation(bundle: bundle)
        try testStoredRecordRerendersForCurrentLanguage(bundle: bundle)
        try testExistingMachineTokensRemainUnchanged()
        print("PipelineHistoryUserIssueTests passed")
    }

    private static func testVersionedErrorBecomesFailedMachineStatus(
        bundle: Bundle
    ) throws {
        let record = QuillUserIssueRecord(
            code: .authenticationFailed,
            context: QuillUserIssueContext(
                httpStatus: 401,
                providerHost: "api.example.com"
            )
        )
        let item = historyItem(postProcessingStatus: try record.encodedStatus())

        guard case .failed(let storedRecord) = item.machineStatus else {
            throw TestFailure("Expected a failed machine status")
        }
        try expect(storedRecord == record, "failed status preserves the safe record")
        try expect(item.userIssueRecord == record, "history exposes the decoded record")

        let title = NoteTitleResolver.displayTitle(
            for: item,
            language: "ko",
            bundle: bundle
        )
        let row = NoteListRowDisplayData(
            item: item,
            retryingIDs: [],
            localizationLanguage: "ko",
            localizationBundle: bundle
        )
        try expect(title == "제공자 인증 확인 필요", "failed title is localized")
        try expect(row.status == .fail, "error record uses failure styling")
        try expect(
            row.preview == "Quill이 선택한 제공자에 인증하지 못했습니다.",
            "failure preview uses friendly localized body"
        )
    }

    private static func testVersionedWarningRemainsCompleted(
        bundle: Bundle
    ) throws {
        let warning = QuillUserIssueRecord(code: .postProcessingFailed)
        let item = historyItem(
            transcript: "Original transcript remains available",
            postProcessingStatus: try warning.encodedStatus()
        )

        try expect(item.machineStatus == .completed, "warning does not fail the note")
        try expect(item.userIssueRecord == warning, "warning remains available to render")
        let row = NoteListRowDisplayData(
            item: item,
            retryingIDs: [],
            localizationLanguage: "en",
            localizationBundle: bundle
        )
        try expect(row.status == .done, "warning note is completed")
        try expect(
            item.postProcessedTranscript == "Original transcript remains available",
            "warning note keeps transcript content"
        )
    }

    private static func testLegacyErrorUsesGenericSafePresentation(
        bundle: Bundle
    ) throws {
        let rawLegacyDetail = "HTTP 500 /Users/private.wav RAW_PROVIDER_BODY"
        let item = historyItem(
            postProcessingStatus: "Error: \(rawLegacyDetail)"
        )

        guard case .failed(let record) = item.machineStatus else {
            throw TestFailure("Expected legacy history to remain failed")
        }
        try expect(record.code == .legacy, "legacy row gets a stable generic code")
        try expect(record.context == QuillUserIssueContext(), "legacy raw detail is discarded")

        let title = NoteTitleResolver.displayTitle(
            for: item,
            language: "en",
            bundle: bundle
        )
        let row = NoteListRowDisplayData(
            item: item,
            retryingIDs: [],
            localizationLanguage: "en",
            localizationBundle: bundle
        )
        try expect(title == "Transcription failed", "legacy title stays familiar")
        try expect(
            row.preview == "This older history item does not include a safe error category.",
            "legacy preview is generic"
        )
        try expect(!title.contains(rawLegacyDetail), "title hides legacy raw detail")
        try expect(!row.preview.contains(rawLegacyDetail), "preview hides legacy raw detail")
    }

    private static func testStoredRecordRerendersForCurrentLanguage(
        bundle: Bundle
    ) throws {
        let record = QuillUserIssueRecord(code: .networkUnavailable)
        let item = historyItem(postProcessingStatus: try record.encodedStatus())

        let english = item.userIssuePresentation(language: "en", bundle: bundle)
        let korean = item.userIssuePresentation(language: "ko", bundle: bundle)

        try expect(english?.title == "No network connection", "English title is resolved at render time")
        try expect(korean?.title == "네트워크 연결 없음", "Korean title is resolved at render time")
        try expect(english?.body != korean?.body, "stored status does not pin a locale")
    }

    private static func testExistingMachineTokensRemainUnchanged() throws {
        try expect(historyItem(postProcessingStatus: "importing").machineStatus == .importing, "importing token")
        try expect(historyItem(postProcessingStatus: "live-recording").machineStatus == .liveRecording, "live token")
        try expect(
            historyItem(postProcessingStatus: PipelineHistoryItem.cloudTranscribingStatus).machineStatus == .cloudTranscribing,
            "cloud token"
        )
        let recovered = historyItem(
            postProcessingStatus: PipelineHistoryItem.recoveredRecordingStatus
        )
        guard case .recovered = recovered.machineStatus else {
            throw TestFailure("Expected recovered token")
        }
    }

    private static func historyItem(
        transcript: String = "",
        postProcessingStatus: String
    ) -> PipelineHistoryItem {
        PipelineHistoryItem(
            timestamp: Date(timeIntervalSince1970: 1),
            rawTranscript: transcript,
            postProcessedTranscript: transcript,
            postProcessingPrompt: nil,
            contextSummary: "",
            contextPrompt: nil,
            contextScreenshotDataURL: nil,
            contextScreenshotStatus: "No screenshot",
            postProcessingStatus: postProcessingStatus,
            debugStatus: "Done",
            customVocabulary: ""
        )
    }

    private static func compiledLocalizationBundle() throws -> Bundle {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        guard let bundle = Bundle(path: root.appendingPathComponent("build/localization").path) else {
            throw TestFailure("Unable to create localization test bundle")
        }
        return bundle
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ label: String
    ) throws {
        guard condition() else { throw TestFailure(label) }
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
