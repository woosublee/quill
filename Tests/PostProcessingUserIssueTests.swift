import Foundation

#if !QUILL_GROUPED_TEST_RUNNER
@main
#endif
struct PostProcessingUserIssueTests {
    static func main() throws {
        try testPostProcessingErrorsMapToWarningRecords()
        try testPostProcessingFailureReasonsStayStructured()
        try testProviderContextLimitAndHTTPTimeoutUseAccurateIssues()
        try testCommandTimeoutUsesEditSpecificCopy()
        try testRawFallbackOutcomeIsPersistedWithTheOriginalTranscript()
        try testRequestFailuresKeepOnlyAllowlistedProviderCode()
        try testNonSuccessResponsesDoNotStoreRawBodies()
        print("PostProcessingUserIssueTests passed")
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
