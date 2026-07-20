import Foundation

@main
struct QuillUserIssueTests {
    static func main() throws {
        let bundle = try compiledLocalizationBundle()
        try testEveryCodeHasCompleteEnglishAndKoreanPresentation(bundle: bundle)
        try testSeverityAndRecoveryActions()
        try testVersionedPersistenceRoundTripAndRejection()
        try testPersistedPayloadExcludesPrivateDiagnostics()
        try testCompactMessageAndSafeDetailsAreDeterministic(bundle: bundle)
        print("QuillUserIssueTests passed")
    }

    private static func testEveryCodeHasCompleteEnglishAndKoreanPresentation(
        bundle: Bundle
    ) throws {
        for code in QuillUserIssueCode.allCases {
            let record = QuillUserIssueRecord(code: code)
            let english = record.presentation(language: "en", bundle: bundle)
            let korean = record.presentation(language: "ko", bundle: bundle)

            for (language, presentation) in [("en", english), ("ko", korean)] {
                try expect(!presentation.title.isEmpty, "\(code.rawValue) has a \(language) title")
                try expect(!presentation.body.isEmpty, "\(code.rawValue) has a \(language) body")
                try expect(!presentation.suggestion.isEmpty, "\(code.rawValue) has a \(language) suggestion")
                try expect(!presentation.compactMessage.isEmpty, "\(code.rawValue) has a \(language) compact message")
                try expect(!presentation.title.contains("%"), "\(code.rawValue) title has no unresolved placeholder")
                try expect(!presentation.body.contains("%"), "\(code.rawValue) body has no unresolved placeholder")
                try expect(!presentation.suggestion.contains("%"), "\(code.rawValue) suggestion has no unresolved placeholder")
            }

            try expect(english.title != korean.title, "\(code.rawValue) title is localized")
            try expect(english.body != korean.body, "\(code.rawValue) body is localized")
            try expect(english.suggestion != korean.suggestion, "\(code.rawValue) suggestion is localized")
        }
    }

    private static func testSeverityAndRecoveryActions() throws {
        let warningCodes: Set<QuillUserIssueCode> = [
            .postProcessingFailed,
            .postProcessingRateLimited,
            .postProcessingGuardFallback
        ]

        for code in QuillUserIssueCode.allCases {
            let record = QuillUserIssueRecord(code: code)
            let expectedSeverity: QuillUserIssueSeverity = warningCodes.contains(code)
                ? .warning
                : .error
            try expect(record.severity == expectedSeverity, "\(code.rawValue) default severity")
        }

        try expect(
            QuillUserIssueRecord(code: .networkUnavailable).recoveryAction == .retryTranscription,
            "offline transcription can retry"
        )
        try expect(
            QuillUserIssueRecord(code: .authenticationFailed).recoveryAction == .openProviderSettings,
            "authentication opens provider settings"
        )
        try expect(
            QuillUserIssueRecord(code: .localModelMissing).recoveryAction == .openModelsSettings,
            "missing local model opens Models settings"
        )
        try expect(
            QuillUserIssueRecord(code: .microphonePermissionDenied).recoveryAction == .openMicrophoneSettings,
            "microphone denial opens microphone settings"
        )
        try expect(
            QuillUserIssueRecord(code: .speechRecognitionPermissionDenied).recoveryAction == .openSpeechRecognitionSettings,
            "speech denial opens speech settings"
        )
        try expect(
            QuillUserIssueRecord(code: .screenRecordingPermissionDenied).recoveryAction == .openScreenRecordingSettings,
            "screen denial opens screen settings"
        )
        try expect(
            QuillUserIssueRecord(code: .postProcessingGuardFallback).recoveryAction == .none,
            "guard fallback does not trigger automatic recovery"
        )
    }

    private static func testVersionedPersistenceRoundTripAndRejection() throws {
        let record = QuillUserIssueRecord(
            code: .rateLimited,
            context: QuillUserIssueContext(
                httpStatus: 429,
                providerHost: "api.example.com",
                modelID: "provider/model-v1",
                retryExhausted: true
            )
        )

        let status = try record.encodedStatus()
        try expect(
            status.hasPrefix(QuillUserIssueRecord.persistedStatusPrefix),
            "encoded status has the v1 prefix"
        )
        let decoded = try QuillUserIssueRecord.decodePersistedStatus(status)
        try expect(decoded == record, "v1 status round-trips")

        try expectThrows(.unsupportedSchemaVersion(2)) {
            _ = try QuillUserIssueRecord.decodePersistedStatus(
                status.replacingOccurrences(of: "user-issue:v1:", with: "user-issue:v2:")
            )
        }
        try expectThrows(.invalidEncoding) {
            _ = try QuillUserIssueRecord.decodePersistedStatus("user-issue:v1:not-base64!")
        }
        try expectThrows(.invalidPrefix) {
            _ = try QuillUserIssueRecord.decodePersistedStatus("Error: legacy raw detail")
        }
    }

    private static func testPersistedPayloadExcludesPrivateDiagnostics() throws {
        let sentinels = [
            "sk-secret-api-key",
            "/Users/example/private-recording.wav",
            "RAW_PROVIDER_BODY",
            "STDERR_MARKER",
            "PROMPT_MARKER",
            "TRANSCRIPT_MARKER"
        ]
        let issue = QuillUserIssueError(
            record: QuillUserIssueRecord(
                code: .localTranscriptionFailed,
                context: QuillUserIssueContext(
                    localBackend: "Native Whisper",
                    processExitCode: 7
                )
            ),
            privateDiagnostic: sentinels.joined(separator: " | ")
        )

        let status = try issue.record.encodedStatus()
        let payload = try decodedPayloadString(status)
        for sentinel in sentinels {
            try expect(!payload.contains(sentinel), "persisted payload excludes \(sentinel)")
        }
        try expect(issue.privateDiagnostic.contains("STDERR_MARKER"), "private diagnostic remains log-only")
    }

    private static func testCompactMessageAndSafeDetailsAreDeterministic(
        bundle: Bundle
    ) throws {
        let record = QuillUserIssueRecord(
            code: .localTranscriptionFailed,
            context: QuillUserIssueContext(
                httpStatus: 503,
                providerHost: "api.example.com",
                modelID: "provider/model-v1",
                localBackend: "Native Whisper",
                processExitCode: 7,
                retryExhausted: true
            )
        )
        let english = record.presentation(language: "en", bundle: bundle)
        let korean = record.presentation(language: "ko", bundle: bundle)

        try expect(english.compactMessage == english.title, "compact message uses the stable title")
        try expect(
            english.detailsRows == [
                QuillUserIssueDetailsRow(label: "HTTP status", value: "503"),
                QuillUserIssueDetailsRow(label: "Provider", value: "api.example.com"),
                QuillUserIssueDetailsRow(label: "Model", value: "provider/model-v1"),
                QuillUserIssueDetailsRow(label: "Local backend", value: "Native Whisper"),
                QuillUserIssueDetailsRow(label: "Process exit code", value: "7"),
                QuillUserIssueDetailsRow(label: "Retry attempts exhausted", value: "Yes")
            ],
            "English details use an allowlisted stable order"
        )
        try expect(
            korean.detailsRows == [
                QuillUserIssueDetailsRow(label: "HTTP 상태", value: "503"),
                QuillUserIssueDetailsRow(label: "제공자", value: "api.example.com"),
                QuillUserIssueDetailsRow(label: "모델", value: "provider/model-v1"),
                QuillUserIssueDetailsRow(label: "로컬 백엔드", value: "Native Whisper"),
                QuillUserIssueDetailsRow(label: "프로세스 종료 코드", value: "7"),
                QuillUserIssueDetailsRow(label: "재시도 횟수 소진", value: "예")
            ],
            "Korean details localize labels without changing safe values"
        )
    }

    private static func decodedPayloadString(_ status: String) throws -> String {
        let encoded = String(status.dropFirst(QuillUserIssueRecord.persistedStatusPrefix.count))
        var base64 = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - base64.count % 4) % 4
        base64 += String(repeating: "=", count: padding)
        guard let data = Data(base64Encoded: base64),
              let text = String(data: data, encoding: .utf8) else {
            throw TestFailure("Unable to decode persisted payload")
        }
        return text
    }

    private static func compiledLocalizationBundle() throws -> Bundle {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        guard let bundle = Bundle(path: root.appendingPathComponent("build/localization").path) else {
            throw TestFailure("Unable to create localization test bundle")
        }
        return bundle
    }

    private static func expectThrows(
        _ expected: QuillUserIssuePersistenceError,
        operation: () throws -> Void
    ) throws {
        do {
            try operation()
            throw TestFailure("Expected persistence error \(expected)")
        } catch let error as QuillUserIssuePersistenceError {
            try expect(error == expected, "Expected \(expected), got \(error)")
        }
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
