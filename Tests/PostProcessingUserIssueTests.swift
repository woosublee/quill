import Foundation
import QuillAITextCore
import QuillUserIssueCore

#if !QUILL_GROUPED_TEST_RUNNER
@main
#endif
struct PostProcessingUserIssueTests {
    static func main() throws {
        try testPostProcessingErrorsMapToWarningRecords()
        try testSharedRecordMatchesTheMacIssue()
        try testFailedCleanupOutcomesStayFixed()
        try testPostProcessingFailureReasonsStayStructured()
        try testProviderContextLimitAndHTTPTimeoutUseAccurateIssues()
        try testCommandTimeoutUsesEditSpecificCopy()
        try testRawFallbackOutcomeIsPersistedWithTheOriginalTranscript()
        try testRequestFailuresKeepOnlyAllowlistedProviderCode()
        try testNonSuccessResponsesDoNotStoreRawBodies()
        try testSharedPresentationTranslatesEveryLineThroughTheApp()
        print("PostProcessingUserIssueTests passed")
    }

    /// The stored outcome of a failed cleanup (synced as aiProcessingOutcome),
    /// pinned from the Mac's AppState rules before they moved to shared code.
    private static func testFailedCleanupOutcomesStayFixed() throws {
        let cases: [(Error, String)] = [
            (PostProcessingError.outputRejected(.languageMismatch), "raw-fallback:languageMismatch"),
            (PostProcessingError.emptyOutput, "failed:empty-output"),
            (PostProcessingError.requestTimedOut(30, modelID: "synthetic/model"), "failed:request-timed-out"),
            (PostProcessingError.requestFailed(statusCode: 503, providerCode: nil), "failed:post-processing-failed"),
            (PostProcessingError.rateLimited(model: "synthetic/model", retryAfter: 5), "failed:post-processing-failed"),
            (PostProcessingError.requestTimedOut(30, modelID: nil), "failed:request-timed-out"),
            (PostProcessingError.invalidResponse("synthetic"), "failed:post-processing-failed"),
            (PostProcessingError.invalidInput("synthetic"), "failed:post-processing-failed"),
            (PostProcessingError.contextBudgetExceeded, "failed:post-processing-failed"),
            (PostProcessingError.suspectedInstructionExecution, "failed:post-processing-failed"),
            (URLError(.notConnectedToInternet), "failed:post-processing-failed"),
        ]
        for (error, expected) in cases {
            let status = AIProcessingOutcome.afterPostProcessingFailure(error).pipelineHistoryStatus
            guard status == expected else {
                throw NSError(domain: "PostProcessingUserIssueTests", code: 9, userInfo: [
                    NSLocalizedDescriptionKey: "\(error): \(status), expected \(expected)"
                ])
            }
        }
    }

    /// The iPhone shows the same warning as the Mac (private#191) by asking the
    /// shared core which copy keys, rows, and action a record gets. Each app
    /// translates with its own catalog, so every line goes through `localize`.
    private static func testSharedPresentationTranslatesEveryLineThroughTheApp() throws {
        let record = PostProcessingError.requestTimedOut(45, modelID: "slow/model")
            .userIssueRecord(providerHost: "api.example.com", modelID: "slow/model")
        let tagged = record.presentation(localize: QuillUserIssueLocalizer(
            string: { "[\($0)]" },
            seconds: { "<\($0)s>" }
        ))
        let copy = record.code.copy(for: record.context)
        try expect(tagged.title == "[\(copy.titleKey)]", "title goes through the app's catalog")
        try expect(tagged.body == "[\(copy.bodyKey)]", "body goes through the app's catalog")
        try expect(tagged.suggestion == "[\(copy.suggestionKey)]", "suggestion goes through the app's catalog")
        try expect(tagged.recoveryAction == record.recoveryAction, "same recovery action")
        try expect(tagged.recoveryAction == .retryPostProcessing, "a failed cleanup retries cleanup only")
        try expect(
            tagged.detailsRows.allSatisfy { $0.label.hasPrefix("[") },
            "every detail label is translated by the app"
        )
        try expect(
            tagged.detailsRows.contains { $0.value == "<45.0s>" },
            "the timeout uses the app's seconds format"
        )
        try expect(
            QuillUserRecoveryAction.retryPostProcessing.titleKey == "Retry Post-processing",
            "the retry button key is shared"
        )
        try expect(QuillUserRecoveryAction.none.titleKey == nil, "no action has no button")
        // The Mac wrapper translates with the Mac catalog: real English, no raw keys or tags.
        let mac = record.presentation(language: "en")
        try expect(!mac.title.hasPrefix("["), "the Mac title is translated")
        try expect(
            mac.detailsRows.contains { $0.value == "45 seconds" },
            "the Mac formats the timeout with its catalog"
        )
    }

    /// The iPhone stores `userIssueRecord` directly (private#160), so it must
    /// be the record the Mac's `userIssue` wraps, field for field.
    private static func testSharedRecordMatchesTheMacIssue() throws {
        let errors: [PostProcessingError] = [
            .requestFailed(statusCode: 401, providerCode: "invalid_api_key"),
            .requestFailed(statusCode: 400, providerCode: "context_length_exceeded"),
            .requestFailed(statusCode: 503, providerCode: nil),
            .rateLimited(model: "limited/model", retryAfter: 30),
            .requestTimedOut(45, modelID: "slow/model"),
            .emptyOutput,
            .outputRejected(.languageMismatch),
        ]
        for error in errors {
            let record = error.userIssueRecord(providerHost: "api.example.com", modelID: "configured/model")
            let mac = error.userIssue(providerHost: "api.example.com", modelID: "configured/model").record
            guard record == mac else {
                throw NSError(domain: "PostProcessingUserIssueTests", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "\(error): shared \(record) differs from Mac \(mac)"
                ])
            }
            guard record.severity == .warning else {
                throw NSError(domain: "PostProcessingUserIssueTests", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "\(error): a failed cleanup is a warning"
                ])
            }
        }
        let timedOut = PostProcessingError.requestTimedOut(45, modelID: "slow/model")
            .userIssueRecord(providerHost: nil, modelID: "configured/model", localBackend: "Local AI")
        guard timedOut.context.modelID == "slow/model",
              timedOut.context.requestTimeoutSeconds == 45,
              timedOut.context.localBackend == "Local AI",
              timedOut.context.postProcessingFailureReason == .requestTimedOut else {
            throw NSError(domain: "PostProcessingUserIssueTests", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "timeout context: \(timedOut.context)"
            ])
        }
    }

    private static func testPostProcessingErrorsMapToWarningRecords() throws {
        let cases: [(PostProcessingError, QuillUserIssueCode, QuillUserRecoveryAction)] = [
            (.requestFailed(statusCode: 401, providerCode: "invalid_api_key"), .authenticationFailed, .openProviderSettings),
            (.requestFailed(statusCode: 500, providerCode: nil), .postProcessingFailed, .retryPostProcessing),
            (.requestFailed(statusCode: 413, providerCode: nil), .postProcessingPayloadTooLarge, .none),
            (.rateLimited(model: "provider/model", retryAfter: 10), .postProcessingRateLimited, .retryPostProcessing),
            (.invalidResponse("missing content"), .postProcessingFailed, .retryPostProcessing),
            (.emptyOutput, .postProcessingFailed, .retryPostProcessing),
            (.requestTimedOut(30), .requestTimedOut, .retryPostProcessing),
            (.suspectedInstructionExecution, .postProcessingGuardFallback, .none),
            (.outputRejected(.languageMismatch), .postProcessingGuardFallback, .none)
        ]

        for (error, expectedCode, expectedAction) in cases {
            let issue = error.userIssue(
                providerHost: "api.example.com",
                modelID: "provider/model"
            )
            try expect(issue.record.code == expectedCode, "\(error) stable code")
            try expect(issue.record.severity == .warning, "\(error) is a non-terminal warning")
            try expect(issue.record.recoveryAction == expectedAction, "\(error) recovery action")
            try expect(issue.record.context.providerHost == "api.example.com", "safe provider context")
            try expect(issue.record.context.modelID == "provider/model", "safe model context")
            if case .requestTimedOut = error {
                try expect(
                    issue.record.context.operation == .postProcessing,
                    "timeout identifies post-processing operation"
                )
                let presentation = issue.record.presentation(language: "en")
                try expect(
                    presentation.title == "Transcript cleanup timed out",
                    "timeout uses cleanup-specific copy"
                )
                try expect(
                    presentation.body.contains("original transcript"),
                    "timeout copy explains raw transcript preservation"
                )
                let decoded = try QuillUserIssueRecord.decodePersistedStatus(
                    issue.record.persistedStatus
                )
                try expect(
                    decoded.code == .requestTimedOut,
                    "timeout code round-trips"
                )
                try expect(
                    decoded.context.operation == .postProcessing,
                    "timeout operation round-trips"
                )
            }
        }
    }

    private static func testPostProcessingFailureReasonsStayStructured() throws {
        let cases: [(PostProcessingError, PostProcessingFailureReason, TimeInterval?)] = [
            (.requestTimedOut(120, modelID: "local-qwen"), .requestTimedOut, 120),
            (.contextBudgetExceeded, .contextBudgetExceeded, nil),
            (.emptyOutput, .emptyOutput, nil),
            (.invalidResponse("missing content"), .invalidResponse, nil),
            (.requestFailed(statusCode: 500, providerCode: "server_error"), .serviceRequestFailed, nil)
        ]

        for (error, expectedReason, expectedTimeout) in cases {
            let issue = error.userIssue(
                providerHost: "api.example.com",
                modelID: "provider/model"
            )
            try expect(
                issue.record.context.postProcessingFailureReason == expectedReason,
                "\(error) uses a bounded post-processing failure reason"
            )
            try expect(
                issue.record.context.requestTimeoutSeconds == expectedTimeout,
                "\(error) keeps only its effective timeout"
            )
        }

        let timedOut = PostProcessingError.requestTimedOut(
            120,
            modelID: "local-qwen"
        ).userIssue(
            providerHost: nil,
            modelID: "provider/model"
        )
        try expect(
            timedOut.record.context.modelID == "local-qwen",
            "timeout retains the model that timed out"
        )

        let requestFailed = PostProcessingError.requestFailed(
            statusCode: 500,
            providerCode: "server_error"
        ).userIssue(
            providerHost: "api.example.com",
            modelID: "provider/model"
        )
        try expect(
            requestFailed.record.context.providerCode == "server_error",
            "request failure keeps only the allowlisted provider code"
        )
    }

    private static func testProviderContextLimitAndHTTPTimeoutUseAccurateIssues() throws {
        let contextLimit = PostProcessingError.requestFailed(
            statusCode: 400,
            providerCode: "context_length_exceeded"
        ).userIssue(
            providerHost: "api.example.com",
            modelID: "provider/model"
        )
        try expect(
            contextLimit.record.code == .postProcessingFailed,
            "provider context limit is not misclassified as provider setup"
        )
        try expect(
            contextLimit.record.context.postProcessingFailureReason == .contextBudgetExceeded,
            "provider context limit identifies the cleanup context limit"
        )
        try expect(
            contextLimit.record.recoveryAction == .none,
            "provider context limit does not offer a futile retry"
        )

        let serverTimeout = PostProcessingError.requestFailed(
            statusCode: 408,
            providerCode: nil
        ).userIssue(
            providerHost: "api.example.com",
            modelID: "provider/model"
        )
        try expect(
            serverTimeout.record.code == .requestTimedOut,
            "HTTP 408 maps to the timeout issue"
        )
        try expect(
            serverTimeout.record.context.postProcessingFailureReason == .requestTimedOut,
            "HTTP 408 records the timeout reason"
        )
        try expect(
            serverTimeout.record.context.requestTimeoutSeconds == nil,
            "HTTP 408 does not invent a client request limit"
        )
    }

    private static func testCommandTimeoutUsesEditSpecificCopy() throws {
        let issue = PostProcessingError.requestTimedOut(20).userIssue(
            providerHost: "api.example.com",
            modelID: "provider/model",
            operation: .commandTransform
        )
        let presentation = issue.record.presentation(language: "en")

        try expect(issue.record.code == .requestTimedOut, "command timeout code")
        try expect(
            issue.record.context.operation == .commandTransform,
            "command timeout operation"
        )
        try expect(
            presentation.title == "Text edit timed out",
            "command timeout uses edit-specific title"
        )
        try expect(
            presentation.body.contains("selected text"),
            "command timeout explains selected-text fallback"
        )
    }

    private static func testRawFallbackOutcomeIsPersistedWithTheOriginalTranscript() throws {
        let rawTranscript = "이번 주 금요일에 출시합니다."
        let item = PipelineHistoryItem(
            timestamp: Date(timeIntervalSince1970: 1),
            rawTranscript: rawTranscript,
            postProcessedTranscript: rawTranscript,
            postProcessingPrompt: nil,
            contextSummary: "",
            contextScreenshotDataURL: nil,
            contextScreenshotStatus: "No screenshot",
            postProcessingStatus: "Post-processing was not applied; the original transcript was kept.",
            aiProcessingOutcome: "raw-fallback:languageMismatch",
            debugStatus: "",
            customVocabulary: ""
        )

        try expect(
            item.aiProcessingOutcome == "raw-fallback:languageMismatch",
            "history retains the typed raw fallback outcome"
        )
        try expect(
            item.rawTranscript == rawTranscript && item.postProcessedTranscript == rawTranscript,
            "raw fallback history keeps the non-empty original transcript"
        )
    }

    private static func testRequestFailuresKeepOnlyAllowlistedProviderCode() throws {
        let sentinel = "RAW_PROVIDER_BODY sk-secret-api-key /Users/private prompt transcript stderr"
        let data = try JSONSerialization.data(withJSONObject: [
            "error": [
                "code": "invalid_api_key",
                "type": "authentication_error",
                "message": sentinel
            ]
        ])
        let providerCode = PostProcessingService.safeProviderErrorCode(from: data)
        let error = PostProcessingError.requestFailed(
            statusCode: 401,
            providerCode: providerCode
        )
        let issue = error.userIssue(
            providerHost: "api.example.com",
            modelID: "provider/model"
        )
        let payload = try decodedPayloadString(issue.record.encodedStatus())

        try expect(providerCode == "invalid_api_key", "allowlisted provider code is preserved")
        try expect(!payload.contains(sentinel), "raw provider message is not persisted")
        try expect(!error.localizedDescription.contains(sentinel), "raw provider message is not displayed")
    }

    private static func testNonSuccessResponsesDoNotStoreRawBodies() throws {
        let source = try String(
            contentsOfFile: "Sources/PostProcessingService.swift",
            encoding: .utf8
        )
        try expect(
            !source.contains("let message = String(data: data, encoding: .utf8) ?? \"\""),
            "non-success responses do not convert raw bodies into errors"
        )
    }

    private static func decodedPayloadString(_ status: String) throws -> String {
        let encoded = String(status.dropFirst(QuillUserIssueRecord.persistedStatusPrefix.count))
        var base64 = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let text = String(data: data, encoding: .utf8) else {
            throw TestFailure("Unable to decode persisted payload")
        }
        return text
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
