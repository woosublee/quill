import Foundation

@main
struct QuillUserIssueTests {
    static func main() throws {
        let bundle = try compiledLocalizationBundle()
        try testEveryCodeHasCompleteEnglishAndKoreanPresentation(bundle: bundle)
        try testSeverityAndRecoveryActions()
        try testVersionedPersistenceRoundTripAndRejection()
        try testUnknownFutureOperationPreservesPersistedIssue(bundle: bundle)
        try testPersistedPayloadExcludesPrivateDiagnostics()
        try testLocalIssueUsesBoundedDiagnosticCategoryAndExcerpt()
        try testMissingProviderAPIKeyFactory()
        try testConnectionLostOffersLocalizedRetryAndNetworkGuidance(bundle: bundle)
        try testOfflineTransportFailuresKeepExistingGuidance(bundle: bundle)
        try testTransportTimeoutClassificationIsPreserved()
        try testCompactMessageAndSafeDetailsAreDeterministic(bundle: bundle)
        try testMeetingSummaryLanguageUnavailableAndProviderCodeDetails(bundle: bundle)
        try testMeetingSummaryFailureSubtypeUsesSafeLocalizedDetails(bundle: bundle)
        try testPostProcessingFailureReasonUsesLocalizedCopyAndDetails(bundle: bundle)
        try testPostProcessingDiagnosticFieldsRemainBackwardCompatible(bundle: bundle)
        try testFractionalPostProcessingTimeoutIsNotTruncated(bundle: bundle)
        try testMeetingSummaryIssueActionResolver()
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
            .postProcessingGuardFallback,
            .postProcessingPayloadTooLarge,
            .localAIModelUnavailable,
            .localAIStartFailed,
            .localAIProcessExited,
            .contextUnavailable,
            .meetingSummaryUnavailable,
            .meetingSummaryInvalidResponse,
            .historyPersistenceUnavailable,
            .historyRecovered
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
            QuillUserIssueRecord(code: .localAIModelUnavailable).recoveryAction
                == .openModelsSettings,
            "unavailable Local AI model opens Models settings"
        )
        try expect(
            QuillUserIssueRecord(code: .localAIStartFailed).recoveryAction
                == .retryTranscription,
            "Local AI startup can retry"
        )
        try expect(
            QuillUserIssueRecord(code: .localAIProcessExited).recoveryAction
                == .retryTranscription,
            "Local AI process exit can retry"
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
            QuillUserIssueRecord(code: .meetingSummaryUnavailable).recoveryAction == .none,
            "meeting summary unavailable has no recovery action"
        )
        try expect(
            QuillUserIssueRecord(code: .meetingSummaryInvalidResponse).recoveryAction == .none,
            "meeting summary invalid response has no recovery action"
        )
        try expect(
            QuillUserIssueRecord(code: .historyPersistenceUnavailable).recoveryAction == .none,
            "non-durable history is informational only"
        )
        let recoveredHistory = QuillUserIssueRecord(code: .historyRecovered)
        try expect(
            recoveredHistory.recoveryAction == .none,
            "recovered durable history does not need recovery action"
        )
        let recoveredPresentation = recoveredHistory.presentation()
        try expect(
            recoveredPresentation.detailsRows.isEmpty,
            "recovered history does not expose backup metadata"
        )
        try expect(
            !recoveredPresentation.body.contains("History Recovery")
                && !recoveredPresentation.body.contains("backupName"),
            "recovered history copy does not expose a backup path or name"
        )
        try expect(
            QuillUserIssueRecord(code: .screenRecordingPermissionDenied).recoveryAction == .openScreenRecordingSettings,
            "screen denial opens screen settings"
        )
        try expect(
            QuillUserIssueRecord(code: .postProcessingGuardFallback).recoveryAction == .none,
            "guard fallback does not trigger automatic recovery"
        )
        try expect(
            QuillUserIssueRecord(code: .contextUnavailable).recoveryAction == .none,
            "context unavailable is informational only, no recovery action"
        )
    }

    private static func testMeetingSummaryFailureSubtypeUsesSafeLocalizedDetails(
        bundle: Bundle
    ) throws {
        let record = QuillUserIssueRecord(
            code: .meetingSummaryInvalidResponse,
            context: QuillUserIssueContext(
                providerHost: "api.example.com",
                modelID: "qwen2.5-7b-instruct",
                meetingSummaryFailureSubtype: .responseEnvelope
            )
        )
        let english = record.presentation(language: "en", bundle: bundle)
        let korean = record.presentation(language: "ko", bundle: bundle)

        try expect(english.detailsRows == [
            QuillUserIssueDetailsRow(label: "Provider", value: "api.example.com"),
            QuillUserIssueDetailsRow(label: "Model", value: "qwen2.5-7b-instruct"),
            QuillUserIssueDetailsRow(label: "Failure reason", value: "Response envelope")
        ], "summary failure Details append the safe reason after provider and model")
        try expect(korean.detailsRows == [
            QuillUserIssueDetailsRow(label: "제공자", value: "api.example.com"),
            QuillUserIssueDetailsRow(label: "모델", value: "qwen2.5-7b-instruct"),
            QuillUserIssueDetailsRow(label: "실패 원인", value: "응답 형식")
        ], "summary failure reason is localized")

        let unrelated = QuillUserIssueRecord(
            code: .networkUnavailable,
            context: QuillUserIssueContext(
                meetingSummaryFailureSubtype: .responseEnvelope
            )
        ).presentation(language: "en", bundle: bundle)
        try expect(
            !unrelated.detailsRows.contains(
                QuillUserIssueDetailsRow(
                    label: "Failure reason",
                    value: "Response envelope"
                )
            ),
            "only summary invalid-response issues expose a summary failure reason"
        )

        let legacy = try JSONDecoder().decode(
            QuillUserIssueContext.self,
            from: Data(#"{"modelID":"legacy/model"}"#.utf8)
        )
        let unknown = try JSONDecoder().decode(
            QuillUserIssueContext.self,
            from: Data(#"{"meetingSummaryFailureSubtype":"unrecognized-subtype"}"#.utf8)
        )
        try expect(
            legacy.meetingSummaryFailureSubtype == nil
                && unknown.meetingSummaryFailureSubtype == nil,
            "legacy and unknown summary failure subtypes decode without discarding the issue"
        )
    }

    private static func testPostProcessingFailureReasonUsesLocalizedCopyAndDetails(
        bundle: Bundle
    ) throws {
        let emptyOutput = QuillUserIssueRecord(
            code: .postProcessingFailed,
            context: QuillUserIssueContext(
                modelID: "qwen2.5-7b",
                localBackend: "Local AI",
                operation: .postProcessing,
                postProcessingFailureReason: .emptyOutput
            )
        )
        let english = emptyOutput.presentation(language: "en", bundle: bundle)
        let korean = emptyOutput.presentation(language: "ko", bundle: bundle)

        try expect(
            english.title == "Transcript cleanup returned no text",
            "empty cleanup output has a specific English title"
        )
        try expect(
            korean.title == "전사문 정리 결과가 비어 있습니다",
            "empty cleanup output has a specific Korean title"
        )
        try expect(
            english.detailsRows.contains(
                QuillUserIssueDetailsRow(
                    label: "Failure reason",
                    value: "Model returned no cleanup text"
                )
            ),
            "empty cleanup output exposes a safe English reason"
        )
        try expect(
            korean.detailsRows.contains(
                QuillUserIssueDetailsRow(
                    label: "실패 원인",
                    value: "모델이 정리 결과를 반환하지 않았습니다"
                )
            ),
            "empty cleanup output exposes a safe Korean reason"
        )
    }

    private static func testPostProcessingDiagnosticFieldsRemainBackwardCompatible(
        bundle: Bundle
    ) throws {
        let timeout = QuillUserIssueRecord(
            code: .requestTimedOut,
            context: QuillUserIssueContext(
                modelID: "qwen2.5-7b",
                localBackend: "Local AI",
                operation: .postProcessing,
                postProcessingFailureReason: .requestTimedOut,
                requestTimeoutSeconds: 120
            )
        )
        let english = timeout.presentation(language: "en", bundle: bundle)
        let korean = timeout.presentation(language: "ko", bundle: bundle)

        try expect(
            english.detailsRows.contains(
                QuillUserIssueDetailsRow(
                    label: "Request timeout",
                    value: "120 seconds"
                )
            ),
            "cleanup timeout exposes the English effective timeout"
        )
        try expect(
            korean.detailsRows.contains(
                QuillUserIssueDetailsRow(
                    label: "요청 제한 시간",
                    value: "120초"
                )
            ),
            "cleanup timeout exposes the Korean effective timeout"
        )

        let legacy = try JSONDecoder().decode(
            QuillUserIssueContext.self,
            from: Data(#"{"modelID":"legacy/model"}"#.utf8)
        )
        try expect(
            legacy.postProcessingFailureReason == nil
                && legacy.requestTimeoutSeconds == nil,
            "legacy issue context omits new optional diagnostics"
        )
        let legacyPresentation = QuillUserIssueRecord(
            code: .postProcessingFailed,
            context: QuillUserIssueContext(
                modelID: legacy.modelID,
                operation: .postProcessing
            )
        ).presentation(language: "en", bundle: bundle)
        try expect(
            legacyPresentation.title == "Transcript cleanup was skipped",
            "legacy cleanup issue keeps compatible generic copy"
        )
    }

    private static func testFractionalPostProcessingTimeoutIsNotTruncated(
        bundle: Bundle
    ) throws {
        let timeout = QuillUserIssueRecord(
            code: .requestTimedOut,
            context: QuillUserIssueContext(
                operation: .postProcessing,
                postProcessingFailureReason: .requestTimedOut,
                requestTimeoutSeconds: 0.5
            )
        )
        let english = timeout.presentation(language: "en", bundle: bundle)
        let korean = timeout.presentation(language: "ko", bundle: bundle)

        try expect(
            english.detailsRows.contains(
                QuillUserIssueDetailsRow(
                    label: "Request timeout",
                    value: "0.5 seconds"
                )
            ),
            "fractional English timeout is not truncated"
        )
        try expect(
            korean.detailsRows.contains(
                QuillUserIssueDetailsRow(
                    label: "요청 제한 시간",
                    value: "0.5초"
                )
            ),
            "fractional Korean timeout is not truncated"
        )
    }

    private static func testMeetingSummaryIssueActionResolver() throws {
        let provider = QuillUserIssueRecord(code: .authenticationFailed).presentation()
        let models = QuillUserIssueRecord(code: .localModelMissing).presentation()
        let retryTranscription = QuillUserIssueRecord(code: .networkUnavailable).presentation()
        let none = QuillUserIssueRecord(code: .meetingSummaryUnavailable).presentation()

        try expect(
            MeetingSummaryIssueAction.resolve(provider) == .recovery(.openProviderSettings),
            "summary authentication keeps the provider-settings recovery route"
        )
        try expect(
            MeetingSummaryIssueAction.resolve(models) == .recovery(.openModelsSettings),
            "summary model issues keep the Models settings recovery route"
        )
        try expect(
            MeetingSummaryIssueAction.resolve(retryTranscription) == .retrySummary,
            "summary retry never invokes a transcription retry"
        )
        try expect(
            MeetingSummaryIssueAction.resolve(none) == .retrySummary,
            "summary issues without a recovery action retry summary generation"
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

    private static func testUnknownFutureOperationPreservesPersistedIssue(
        bundle: Bundle
    ) throws {
        let payload = #"{"schemaVersion":1,"code":"request-timed-out","severity":"warning","context":{"modelID":"future/model","operation":"futureOperation"}}"#
        let encodedPayload = Data(payload.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let status = QuillUserIssueRecord.persistedStatusPrefix + encodedPayload

        let record = try QuillUserIssueRecord.decodePersistedStatus(status)

        try expect(record.code == .requestTimedOut, "future operation preserves issue code")
        try expect(record.severity == .warning, "future operation preserves issue severity")
        try expect(record.context.modelID == "future/model", "future operation preserves safe context")
        try expect(record.context.operation == nil, "future operation decodes as an unknown optional classifier")
        try expect(
            record.presentation(language: "en", bundle: bundle).title
                == "Transcription timed out",
            "future operation falls back to generic timeout copy"
        )
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

        let localIssue = QuillUserIssueError.local(
            code: .localAIProcessExited,
            backend: "Local AI",
            modelID: "local-model-id",
            diagnostic: "/Users/private/model.gguf STDERR_SECRET"
        )
        let localPayload = try decodedPayloadString(localIssue.record.encodedStatus())
        try expect(!localPayload.contains("/Users/private"), "local path is private")
        try expect(!localPayload.contains("STDERR_SECRET"), "local stderr is private")
    }

    private static func testLocalIssueUsesBoundedDiagnosticCategoryAndExcerpt() throws {
        let diagnostics = LocalAIDiagnostics(
            category: .serverOutput,
            trailingLines: (0..<16).map { "safe diagnostic \($0)" }
        )
        let issue = QuillUserIssueError.local(
            code: .localAIStartFailed,
            backend: "Local AI",
            modelID: "qwen2.5-7b-instruct",
            diagnosticCategory: diagnostics.category.rawValue,
            diagnosticExcerpt: diagnostics.boundedExcerpt()
        )

        try expect(issue.privateDiagnostic.contains("server-output"), "local diagnostics retain their safe category")
        try expect(issue.privateDiagnostic.contains("safe diagnostic 15"), "local diagnostics retain a trailing excerpt")
        try expect(!issue.privateDiagnostic.contains("safe diagnostic 0"), "local diagnostics omit lines outside the bounded excerpt")
        try expect(issue.privateDiagnostic.count <= QuillUserIssueError.diagnosticCharacterLimit, "local diagnostic excerpt is bounded")
        let payload = try decodedPayloadString(issue.record.encodedStatus())
        try expect(!payload.contains("server-output"), "local diagnostic category is not persisted")
        try expect(!payload.contains("safe diagnostic 15"), "local diagnostic excerpt is not persisted")
    }

    private static func testMissingProviderAPIKeyFactory() throws {
        let issue = QuillUserIssueError.missingProviderAPIKey(
            providerHost: "api.example.com",
            modelID: "provider/model-v1"
        )

        try expect(
            issue.record.code == .providerConfigurationInvalid,
            "missing provider key uses configuration issue"
        )
        try expect(
            issue.record.recoveryAction == .openProviderSettings,
            "missing provider key opens Provider settings"
        )
        try expect(
            issue.record.context.providerHost == "api.example.com",
            "missing provider key keeps safe provider host"
        )
        try expect(
            issue.record.context.modelID == "provider/model-v1",
            "missing provider key keeps safe model ID"
        )
        try expect(
            !issue.privateDiagnostic.lowercased().contains("key="),
            "missing provider key diagnostic excludes credential values"
        )
    }

    private static func testConnectionLostOffersLocalizedRetryAndNetworkGuidance(
        bundle: Bundle
    ) throws {
        let issue = QuillUserIssueError.cloudTransport(
            URLError(.networkConnectionLost),
            providerHost: "api.example.com",
            modelID: "provider/model-v1"
        )
        let english = issue.record.presentation(language: "en", bundle: bundle)
        let korean = issue.record.presentation(language: "ko", bundle: bundle)

        try expect(
            english.title == "Connection lost",
            "연결 끊김을 인터넷 연결 없음으로 잘못 안내하지 않는다"
        )
        try expect(
            english.suggestion == "Try again or switch to another network.",
            "연결 끊김에는 재시도와 다른 네트워크 사용을 안내한다"
        )
        try expect(korean.title == "연결이 끊겼습니다", "연결 끊김 제목을 한국어로 표시한다")
        try expect(
            korean.suggestion == "다시 시도하거나 다른 네트워크를 사용해 보세요.",
            "한국어에서도 재시도와 다른 네트워크 사용을 안내한다"
        )
        try expect(
            english.recoveryAction == .retryTranscription
                && korean.recoveryAction == .retryTranscription,
            "연결 끊김의 기존 전사 재시도 동작을 유지한다"
        )
        try expect(
            english.detailsRows == [
                QuillUserIssueDetailsRow(label: "Provider", value: "api.example.com"),
                QuillUserIssueDetailsRow(label: "Model", value: "provider/model-v1")
            ],
            "연결 끊김에도 기존 제공자와 모델 상세정보를 보존한다"
        )
        let restored = try QuillUserIssueRecord.decodePersistedStatus(issue.persistedStatus)
        try expect(
            restored.presentation(language: "ko", bundle: bundle) == korean,
            "기록을 다시 읽어도 연결 끊김 안내와 복구 동작을 유지한다"
        )
    }

    private static func testOfflineTransportFailuresKeepExistingGuidance(
        bundle: Bundle
    ) throws {
        let codes: [URLError.Code] = [
            .notConnectedToInternet,
            .cannotConnectToHost,
            .cannotFindHost,
            .dnsLookupFailed
        ]
        for code in codes {
            let issue = QuillUserIssueError.cloudTransport(
                URLError(code),
                providerHost: "api.example.com",
                modelID: "provider/model-v1"
            )
            let english = issue.record.presentation(language: "en", bundle: bundle)
            let korean = issue.record.presentation(language: "ko", bundle: bundle)

            try expect(issue.record.code == .networkUnavailable, "\(code)는 기존 네트워크 오류 분류를 유지한다")
            try expect(english.title == "No network connection", "\(code)는 기존 영어 안내를 유지한다")
            try expect(korean.title == "네트워크 연결 없음", "\(code)는 기존 한국어 안내를 유지한다")
            try expect(english.recoveryAction == .retryTranscription, "\(code)는 전사를 재시도할 수 있다")
        }
    }

    private static func testTransportTimeoutClassificationIsPreserved() throws {
        for (code, timedOut) in [(URLError.Code.timedOut, false), (.networkConnectionLost, true)] {
            let issue = QuillUserIssueError.cloudTransport(
                URLError(code),
                timedOut: timedOut,
                providerHost: "api.example.com",
                modelID: "provider/model-v1"
            )
            try expect(issue.record.code == .requestTimedOut, "명시적인 시간 초과는 연결 끊김보다 우선한다")
            try expect(issue.record.recoveryAction == .retryTranscription, "시간 초과의 재시도 동작을 유지한다")
        }
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

    private static func testMeetingSummaryLanguageUnavailableAndProviderCodeDetails(
        bundle: Bundle
    ) throws {
        let unavailable = QuillUserIssueRecord(
            code: .meetingSummaryLanguageUnavailable,
            context: QuillUserIssueContext(
                providerCode: "temporarily_unavailable"
            )
        )
        try expect(
            unavailable.recoveryAction == .openModelsSettings,
            "unavailable spoken language opens Models settings"
        )
        try expect(
            unavailable.presentation(language: "en", bundle: bundle).detailsRows
                == [
                    QuillUserIssueDetailsRow(
                        label: "Provider code",
                        value: "temporarily_unavailable"
                    )
                ],
            "provider code is shown as an allowlisted detail"
        )
        let withoutProviderCode = QuillUserIssueRecord(
            code: .meetingSummaryLanguageUnavailable
        )
        try expect(
            withoutProviderCode.presentation(language: "en", bundle: bundle)
                .detailsRows.isEmpty,
            "empty provider code is omitted from details"
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
