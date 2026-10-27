import CryptoKit
import Foundation
import QuillAITextCore
import QuillProviderCore
import QuillUserIssueCore
import QuillSummaryFormatCore
import QuillSummaryGenerationCore

#if !QUILL_GROUPED_TEST_RUNNER
@main
#endif
struct MeetingSummaryServiceTests {
    private static let summaryLanguage = MeetingSummaryLanguageContext(
        requestedOutputLanguage: "English",
        appliedLanguageCode: "en",
        resolutionSource: .configured
    )

    static func main() async throws {
        try await testCloudRequestUsesSummaryPromptAndStrictJSON()
        try await testLocalRequestUsesLoopbackWithoutAuthorization()
        try await testChatCompletionRequestsStayFixed()
        try testChatCompletionRequestRejectsABadSchema()
        try testUnknownTopLevelKeyIsRejected()
        try testOwnerAndDueDateMayBeNull()
        try testNestedOverviewQuotesAreUnwrappedOnlyWhenAsked()
        try await testExactChunkSizingKeepsTheFractionalByteRatio()
        try await testCompactMergeIsSkippedWithTheSameRoom()
        try await testRateLimitUsesConfiguredFallback()
        try await testRateLimitRetainsAllowlistedProviderCode()
        try await testFallbackTerminalFailureReportsPrimaryModel()
        try await testCloudFallbackRunsOnServerErrorButNotNetworkFailure()
        try await testFailedSummaryFallbackReportsPrimaryError()
        try await testCloudPrimaryFallsBackToLocalModel()
        try await testLocalPrimaryFallsBackToCloudWithoutCalendar()
        try await testLocalPrimaryWithoutFallbackNeverCallsCloud()
        try await testCancelledSummaryNeverFallsBack()
        try await testSummaryFallbackEqualToPrimaryIsNotRetried()
        try await testTraditionalChineseSameAsSpokenUsesTraditionalPromptAndValidator()
        try await testLongTranscriptExtractsEveryChunkThenMerges()
        try await testHierarchyUsesBoundedIntermediateMergesAndCompletionCeiling()
        try await testHierarchyCarriesSingletonTailIntoNextMergeRound()
        try await testUnresolvedCitationReturnsUnverifiedSummaryWithoutExtraModelCall()
        try await testMissingCitationReturnsUnverifiedSummary()
        try await testNullPointCitationReturnsUnverifiedSummary()
        try await testNullOverviewCitationReturnsUnverifiedSummary()
        try await testChunkFailureDoesNotReturnPartialSummary()
        try await testTruncatedResponseReportsOutputTruncated()
        try await testLocalSummaryCountsTokensWithLocalServer()
        try await testLocalMergeLeavesTheFullResponseRoom()
        try await testLocalMergeFallsBackToTheExtractionRoom()
        try testMergePromptUsesSummaryResponseShape()
        try await testLocalSchemaKeepsHanOutOfProseUnlessTheLanguageWritesIt()
        try testUserIssueMapsToSummaryDomainCodes()
        try testInvalidResponseUsesSafeResponseEnvelopeSubtype()
        try testSafeFailureSubtypeMappingsCoverSummaryValidation()
        try testAttemptDoesNotSerializeSecretsOrProviderBody()
        try testProviderCodeAllowlistExcludesUnsafeValues()
        try await testProviderResponseCodeIsNormalizedBeforeErrorPropagation()
        try await testSameAsSpokenKoreanUsesKoreanPromptAndValidator()
        print("MeetingSummaryServiceTests passed")
    }

    private static let successfulReadinessProbe: LocalAIServerManager.ReadinessProbe = { request in
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (Data("{\"choices\":[{\"message\":{\"content\":\"OK\"}}]}".utf8), response)
    }

    private static func testUserIssueMapsToSummaryDomainCodes() throws {
        let unavailableCases: [MeetingSummaryError] = [
            .requestFailed(statusCode: 500, providerCode: nil),
            .rateLimited(model: "m", retryAfter: 1),
            .requestTimedOut(120),
            .invalidInput,
            .sourceChanged
        ]
        for error in unavailableCases {
            let issue = error.userIssue(
                providerHost: "api.example.com",
                modelID: "summary/model",
                localBackend: nil
            )
            try expect(
                issue.code == .meetingSummaryUnavailable,
                "\(error) maps to meetingSummaryUnavailable"
            )
            try expect(
                issue.recoveryAction == .none,
                "\(error) has no recovery action"
            )
        }

        for error: MeetingSummaryError in [.invalidResponse(.responseEnvelope), .emptyOutput()] {
            let issue = error.userIssue(
                providerHost: "api.example.com",
                modelID: "summary/model",
                localBackend: nil
            )
            try expect(
                issue.code == .meetingSummaryInvalidResponse,
                "\(error) maps to meetingSummaryInvalidResponse"
            )
            try expect(
                issue.recoveryAction == .none,
                "\(error) has no recovery action"
            )
        }

        let authIssue = MeetingSummaryError.requestFailed(
            statusCode: 401,
            providerCode: nil
        ).userIssue(
            providerHost: "api.example.com",
            modelID: "summary/model",
            localBackend: nil
        )
        try expect(
            authIssue.code == .authenticationFailed,
            "401 maps to authenticationFailed"
        )
        try expect(
            authIssue.recoveryAction == .openProviderSettings,
            "401 opens provider settings"
        )
    }

    private static func testInvalidResponseUsesSafeResponseEnvelopeSubtype() throws {
        let issue = MeetingSummaryError.invalidResponse(
            .responseEnvelope
        ).userIssue(
            providerHost: "api.example.com",
            modelID: "summary/model",
            localBackend: nil
        )

        try expect(
            issue.context.meetingSummaryFailureSubtype == .responseEnvelope,
            "invalid summary envelopes retain only the safe response-envelope category"
        )
    }

    private static func testSafeFailureSubtypeMappingsCoverSummaryValidation() throws {
        let cases: [(MeetingSummaryError, MeetingSummaryFailureSubtype)] = [
            (.invalidResponse(.jsonSchema), .jsonSchema),
            (.invalidResponse(.outputTruncated), .outputTruncated),
            (.invalidResponse(.contextBudget), .contextBudget),
            (.invalidResponse(.mergeBudget), .mergeBudget),
            (.emptyOutput(), .emptyOutput),
            (.outputRejected(.sourceQuoteMissing), .sourceEvidenceMissing),
            (.outputRejected(.sourceQuoteNotFound), .sourceQuoteNotFound),
            (.outputRejected(.overviewEvidenceCountInvalid), .overviewEvidenceCountInvalid),
            (.outputRejected(.overviewEvidenceQuoteDuplicate), .overviewEvidenceQuoteDuplicate),
            (.outputRejected(.ownerNotGrounded), .ownerNotGrounded),
            (.outputRejected(.dueDateNotGrounded), .dueDateNotGrounded),
            (.outputRejected(.languageMismatch), .languageMismatch)
        ]

        for (error, expectedSubtype) in cases {
            let issue = error.userIssue(
                providerHost: "api.example.com",
                modelID: "summary/model",
                localBackend: nil
            )
            try expect(
                issue.context.meetingSummaryFailureSubtype == expectedSubtype,
                "\(error) maps to the bounded summary failure subtype \(expectedSubtype)"
            )
            let encoded = String(data: try JSONEncoder().encode(issue), encoding: .utf8)!
            try expect(
                encoded.contains(expectedSubtype.rawValue),
                "the app-owned summary failure subtype persists by its closed raw value"
            )
        }
    }

    private static func testAttemptDoesNotSerializeSecretsOrProviderBody() throws {
        let issue = MeetingSummaryError.requestFailed(
            statusCode: 503,
            providerCode: "temporarily_unavailable"
        ).userIssue(
            providerHost: "api.example.com",
            modelID: "summary/model",
            localBackend: nil
        )
        let attempt = MeetingSummaryAttempt(
            occurredAt: Date(timeIntervalSince1970: 2_000),
            outcome: .failed,
            backendKind: .cloud,
            modelID: "summary/model",
            providerHost: "api.example.com",
            language: nil,
            issue: issue
        )
        let encoded = String(data: try JSONEncoder().encode(attempt), encoding: .utf8)!

        precondition(encoded.contains("temporarily_unavailable"))
        precondition(!encoded.contains("sk-secret"))
        precondition(!encoded.contains("provider response body"))
        precondition(!encoded.contains("회의 전사문"))
    }

    private static func testProviderCodeAllowlistExcludesUnsafeValues() throws {
        let unsafeCodes = [
            String(repeating: "x", count: 129),
            "temporarily unavailable",
            "temporary\nunavailable",
            "sk-secret-api-key",
            "Bearer secret-token",
            "Authorization: Bearer secret-token",
            #"{\"error\":{\"message\":\"provider response body\"}}"#,
            "회의 전사문",
            "AIza" + String(repeating: "a", count: 35),
            "ghp_" + String(repeating: "a", count: 36),
            "xoxb-" + [
                String(repeating: "1", count: 12),
                String(repeating: "2", count: 12),
                String(repeating: "a", count: 24)
            ].joined(separator: "-"),
            "sk_live_" + String(repeating: "a", count: 24)
        ]
        for code in unsafeCodes {
            let issue = MeetingSummaryError.requestFailed(
                statusCode: 503,
                providerCode: code
            ).userIssue(
                providerHost: "api.example.com",
                modelID: "summary/model",
                localBackend: nil
            )
            let attempt = MeetingSummaryAttempt(
                occurredAt: Date(timeIntervalSince1970: 2_000),
                outcome: .failed,
                backendKind: .cloud,
                modelID: "summary/model",
                providerHost: "api.example.com",
                language: nil,
                issue: issue
            )
            let encoded = String(
                data: try JSONEncoder().encode(attempt),
                encoding: .utf8
            )!

            try expect(
                issue.context.providerCode == nil,
                "unsafe provider code is discarded: \(code)"
            )
            try expect(
                !encoded.contains(code),
                "unsafe provider code is not serialized: \(code)"
            )
            try expect(
                !issue.presentation().detailsRows.contains { $0.value == code },
                "unsafe provider code is not shown in Details: \(code)"
            )
        }

        let safeCode = "temporarily_unavailable"
        let safeIssue = MeetingSummaryError.requestFailed(
            statusCode: 503,
            providerCode: safeCode
        ).userIssue(
            providerHost: "api.example.com",
            modelID: "summary/model",
            localBackend: nil
        )
        try expect(
            safeIssue.context.providerCode == safeCode,
            "allowlisted provider identifiers remain available for diagnostics"
        )
        let safeAttempt = MeetingSummaryAttempt(
            occurredAt: Date(timeIntervalSince1970: 2_000),
            outcome: .failed,
            backendKind: .cloud,
            modelID: "summary/model",
            providerHost: "api.example.com",
            language: nil,
            issue: safeIssue
        )
        let safeEncoded = String(
            data: try JSONEncoder().encode(safeAttempt),
            encoding: .utf8
        )!
        try expect(
            safeEncoded.contains(safeCode),
            "allowlisted provider code remains in attempt diagnostics"
        )
        try expect(
            safeIssue.presentation().detailsRows.contains {
                $0.label == "Provider code" && $0.value == safeCode
            },
            "allowlisted provider code remains in Details"
        )
    }

    private static func testProviderResponseCodeIsNormalizedBeforeErrorPropagation() async throws {
        let service = makeCloudService { request in
            try providerErrorResponse(
                request: request,
                statusCode: 503,
                code: "sk-secret-api-key"
            )
        }

        do {
            _ = try await service.generate(
                source: MeetingSummarySource(
                    transcript: summaryTranscript,
                    calendar: nil,
                    languageContext: summaryLanguage
                )
            )
            throw MeetingSummaryServiceTestFailure("Expected provider failure")
        } catch let failure as MeetingSummaryServiceTestFailure {
            throw failure
        } catch let error as MeetingSummaryError {
            guard case .requestFailed(
                statusCode: 503,
                providerCode: nil,
                modelID: _
            ) = error else {
                throw MeetingSummaryServiceTestFailure(
                    "unsafe response code must be discarded before propagation"
                )
            }
        }
    }

    private static func testSameAsSpokenKoreanUsesKoreanPromptAndValidator() async throws {
        let recorder = MeetingSummaryRequestRecorder()
        let sourceQuote = "회의에서 다음 주 화요일에 출시하기로 결정했습니다."
        let source = MeetingSummarySource(
            transcript: sourceQuote,
            calendar: nil,
            languageContext: MeetingSummaryLanguageContext(
                requestedOutputLanguage: "",
                appliedLanguageCode: "ko",
                resolutionSource: .engineDetected
            )
        )
        let koreanJSON = #"{"overview":{"text":"팀은 다음 주 화요일에 출시하기로 결정했습니다.","sourceQuotes":["회의에서 다음 주 화요일에 출시하기로 결정했습니다."]},"keyPoints":[],"decisions":[],"actionItems":[],"openQuestions":[]}"#
        let service = makeCloudService { request in
            recorder.record(request)
            return try successResponse(request: request, content: koreanJSON)
        }

        let result = try await service.generate(source: source)
        let request = try recorder.requests().only()
        let messages = try array(try requestBody(request)["messages"])
        let system = try string(try dictionary(messages[0])["content"])

        try expect(
            system.contains("Write generated summary prose in Korean."),
            "Same as spoken Korean uses the stable Korean prompt name"
        )
        try expect(
            result.draft.overview.text == "팀은 다음 주 화요일에 출시하기로 결정했습니다.",
            "Korean generated prose passes validation for Korean source context"
        )
    }

    private static func testCloudRequestUsesSummaryPromptAndStrictJSON() async throws {
        let recorder = MeetingSummaryRequestRecorder()
        let service = makeCloudService { request in
            recorder.record(request)
            return try successResponse(request: request, content: validJSON)
        }
        let start = Date(timeIntervalSince1970: 1_000)
        let source = MeetingSummarySource(
            transcript: summaryTranscript,
            calendar: MeetingSummaryCalendarContext(
                title: "Product Weekly",
                start: start,
                end: start.addingTimeInterval(1_800),
                attendees: ["Adaeze Okafor", "linnea@example.com"]
            ),
            languageContext: summaryLanguage
        )

        let result = try await service.generate(source: source)
        let request = try recorder.requests().only()
        let body = try requestBody(request)
        let messages = try array(body["messages"])
        let system = try string(try dictionary(messages[0])["content"])
        let user = try string(try dictionary(messages[1])["content"])

        try expect(result.draft.overview.text == "Release review", "decoded overview")
        try expect(request.url?.path.hasSuffix("/chat/completions") == true, "chat completions path")
        try expect(
            request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key",
            "cloud authorization"
        )
        try expect(system.contains("source quote"), "evidence contract")
        try expect(
            system.contains("Use no more than two source quotes for overview evidence."),
            "overview evidence is bounded"
        )
        try expect(user.contains("\"feature\":\"meeting_summary_extraction\""), "summary source envelope")
        // #529: calendar events never go to a cloud model.
        guard let calendar = source.calendar else { throw MeetingSummaryServiceTestFailure("Missing calendar") }
        try expectNoCalendar(in: recorder.requests(), calendar: calendar)
        try expect(body["max_tokens"] == nil, "cloud Summary omits the local legacy completion key")
        try expect(body["response_format"] == nil, "a cloud Summary request is not JSON-schema constrained")
        try expect(
            body["max_completion_tokens"] as? Int == 1_024,
            "cloud Summary keeps the 1,024-token completion ceiling"
        )
    }

    /// Pins each Summary request the service hands to its transport, so
    /// moving the request builder into shared code can't change it. Prompt
    /// text is pinned by the prompt tests; here it is only a placeholder.
    /// The local schema is spliced in as text, so it is pinned by the digest
    /// of its exact bytes.
    private static func testChatCompletionRequestsStayFixed() async throws {
        // Its own path, so a cooldown left by another test can't block it.
        let runID = UUID().uuidString
        // Japanese gets the schema that allows Han characters.
        let japaneseTranscript = "リリースの確認です。金曜日に出荷します。"
        let japaneseJSON = #"{"overview":{"text":"リリースの確認です。","sourceQuotes":["リリースの確認です。"]},"keyPoints":[],"decisions":[{"text":"金曜日に出荷します。","sourceQuote":"金曜日に出荷します。"}],"actionItems":[],"openQuestions":[]}"#
        func captured(_ executor: AIProcessingBackendExecutor, outputLanguageCode: String) async throws -> String {
            let japanese = outputLanguageCode == "ja"
            let recorder = MeetingSummaryRequestRecorder()
            let service = MeetingSummaryService(
                backendExecutor: executor,
                fallbackExecutor: nil,
                transport: { request in
                    recorder.record(request)
                    return try successResponse(request: request, content: japanese ? japaneseJSON : validJSON)
                }
            )
            _ = try await service.generate(
                source: MeetingSummarySource(
                    transcript: japanese ? japaneseTranscript : summaryTranscript,
                    calendar: nil,
                    languageContext: MeetingSummaryLanguageContext(
                        requestedOutputLanguage: outputLanguageCode,
                        appliedLanguageCode: outputLanguageCode,
                        resolutionSource: .configured
                    )
                )
            )
            return try canonicalChatRequest(try recorder.requests().only())
                .replacingOccurrences(of: runID, with: "<run>")
        }
        func cloud(_ modelID: String) -> AIProcessingBackendExecutor {
            AIProcessingBackendExecutor(
                choice: .cloud(modelID: modelID),
                cloudBaseURL: "https://api.example.com/openai/v1/\(runID)",
                cloudAPIKey: "test-key"
            )
        }
        func local() -> AIProcessingBackendExecutor {
            let process = MeetingSummaryFakeProcess()
            return AIProcessingBackendExecutor(
                choice: .localAI(modelID: LocalAIModelCatalog.quality.id),
                cloudBaseURL: "https://api.example.com/openai/v1/\(runID)",
                cloudAPIKey: "cloud-secret",
                localServerManager: LocalAIServerManager(
                    launchProcess: { _, _, port, _ in (process, port) },
                    pollHealth: { _ in true },
                    readinessProbe: successfulReadinessProbe,
                    validateModel: { _ in .ready }
                ),
                localAIAvailability: LocalAIProcessingAvailability(
                    isAppleSilicon: true,
                    runnerIsExecutable: true,
                    physicalMemory: 16 * 1024 * 1024 * 1024
                )
            )
        }

        let requests: [(String, String)] = [
            ("cloud", try await captured(cloud("primary/model"), outputLanguageCode: "en")),
            ("cloud default", try await captured(cloud(ModelConfiguration.defaultLLMModelID), outputLanguageCode: "en")),
            ("local en", try await captured(local(), outputLanguageCode: "en")),
            ("local ja", try await captured(local(), outputLanguageCode: "ja"))
        ]
        let pinned: [String: String] = [
            "cloud": #"""
                POST https://api.example.com/openai/v1/<run>/chat/completions
                timeout 120.0
                Authorization: Bearer test-key
                Content-Type: application/json
                {"max_completion_tokens":1024,"messages":[{"content":"<system>","role":"system"},{"content":"<user>","role":"user"}],"model":"primary\/model","temperature":0}
                """#,
            "cloud default": #"""
                POST https://api.example.com/openai/v1/<run>/chat/completions
                timeout 120.0
                Authorization: Bearer test-key
                Content-Type: application/json
                {"include_reasoning":false,"max_completion_tokens":1024,"messages":[{"content":"<system>","role":"system"},{"content":"<user>","role":"user"}],"model":"openai\/gpt-oss-20b","reasoning_effort":"low","temperature":0}
                """#,
            "local en": #"""
                POST http://127.0.0.1:<port>/v1/chat/completions
                timeout 420.0
                Content-Type: application/json
                {"max_completion_tokens":6144,"max_tokens":6144,"messages":[{"content":"<system>","role":"system"},{"content":"<user>","role":"user"}],"model":"local","response_format":"4c864aae676bc8e9b254d3feff39e8808d4a4a8fe082ba577b995c1f66786201","temperature":0}
                """#,
            "local ja": #"""
                POST http://127.0.0.1:<port>/v1/chat/completions
                timeout 420.0
                Content-Type: application/json
                {"max_completion_tokens":6144,"max_tokens":6144,"messages":[{"content":"<system>","role":"system"},{"content":"<user>","role":"user"}],"model":"local","response_format":"e1085cd53a9745799fdf4af191e5ac5d857568928f86b0572aec5ac1941ba26e","temperature":0}
                """#
        ]
        for (label, request) in requests {
            try expect(request == pinned[label], "the \(label) request stays the same:\n\(request)")
        }
    }

    /// A schema that isn't a JSON object would leave a broken body.
    private static func testChatCompletionRequestRejectsABadSchema() throws {
        for schema in ["", "{\"type\":", "[]"] {
            do {
                _ = try ChatCompletionRequest(
                    model: "local",
                    system: "system",
                    user: "user",
                    completionCeiling: 16,
                    responseFormatJSON: schema
                ).urlRequest(
                    baseURL: URL(string: "http://127.0.0.1:8080/v1")!,
                    authorizationToken: nil,
                    timeout: 1
                )
                throw MeetingSummaryServiceTestFailure("a bad schema \(schema) is rejected")
            } catch ChatCompletionRequestError.invalidResponseFormat {}
        }
    }

    /// The request as text: method, URL, headers, timeout, then the body
    /// with sorted keys, each message's text replaced by its role, and the
    /// spliced local schema replaced by the digest of its raw bytes.
    private static func canonicalChatRequest(_ request: URLRequest) throws -> String {
        var body = try requestBody(request)
        if let messages = body["messages"] as? [[String: Any]] {
            body["messages"] = messages.map { message in
                var message = message
                if message["content"] is String {
                    message["content"] = "<\(message["role"] as? String ?? "?")>"
                }
                return message
            }
        }
        if body["response_format"] != nil {
            let rawBody = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            guard let start = rawBody.range(of: #","response_format":"#),
                  rawBody.hasSuffix("}") else {
                throw MeetingSummaryServiceTestFailure("Missing spliced response_format")
            }
            let rawFormat = rawBody[start.upperBound..<rawBody.index(before: rawBody.endIndex)]
            body["response_format"] = SHA256.hash(data: Data(rawFormat.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
        }
        var url = request.url?.absoluteString ?? ""
        if let port = request.url?.port, request.url?.host == "127.0.0.1" {
            url = url.replacingOccurrences(of: ":\(port)/", with: ":<port>/")
        }
        let headers = (request.allHTTPHeaderFields ?? [:])
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }
        let bodyText = String(
            data: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]),
            encoding: .utf8
        ) ?? ""
        return ([
            "\(request.httpMethod ?? "") \(url)",
            "timeout \(request.timeoutInterval)"
        ] + headers + [bodyText]).joined(separator: "\n")
    }

    private static func testLocalRequestUsesLoopbackWithoutAuthorization() async throws {
        let recorder = MeetingSummaryRequestRecorder()
        let process = MeetingSummaryFakeProcess()
        let manager = LocalAIServerManager(
            launchProcess: { _, _, port, _ in (process, port) },
            pollHealth: { _ in true },
            readinessProbe: successfulReadinessProbe,
            validateModel: { _ in .ready }
        )
        let service = MeetingSummaryService(
            backendExecutor: AIProcessingBackendExecutor(
                choice: .localAI(modelID: LocalAIModelCatalog.quality.id),
                cloudBaseURL: "https://api.example.com/openai/v1",
                cloudAPIKey: "cloud-secret",
                localServerManager: manager,
                localAIAvailability: LocalAIProcessingAvailability(
                    isAppleSilicon: true,
                    runnerIsExecutable: true,
                    physicalMemory: 16 * 1024 * 1024 * 1024
                )
            ),
            fallbackExecutor: nil,
            transport: { request in
                recorder.record(request)
                return try successResponse(request: request, content: validJSON)
            }
        )

        let start = Date(timeIntervalSince1970: 1_000)
        _ = try await service.generate(
            source: MeetingSummarySource(
                transcript: summaryTranscript,
                calendar: MeetingSummaryCalendarContext(
                    title: "Product Weekly",
                    start: start,
                    end: start.addingTimeInterval(1_800),
                    attendees: ["Ada", "Lin"]
                ),
                languageContext: summaryLanguage
            )
        )

        let request = try recorder.requests().only()
        let body = try requestBody(request)
        // #529: a local model still gets the calendar event.
        try expect(try userMessage(request).contains("Product Weekly"), "a local request keeps the calendar")
        // The same object the cloud check looks for, escaped in the body.
        try expect(try userMessage(request).contains("\"calendar\":{"), "the calendar object's shape")
        let requestText = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        try expect(requestText.contains("\\\"calendar\\\":{"), "the escaped shape the cloud check uses")
        try expect(request.url?.host == "127.0.0.1", "local loopback host")
        try expect(
            request.value(forHTTPHeaderField: "Authorization") == nil,
            "local authorization omitted"
        )
        try expect(body["model"] as? String == "local", "local request model")
        let ceiling = try int(body["max_completion_tokens"])
        try expect(
            (4_096...6_144).contains(ceiling),
            "local Summary leaves 4,096 to 6,144 tokens for the response"
        )
        try expect(request.timeoutInterval == 420, "a local Summary request waits up to 420 seconds")
        // #611: llama-server samples only JSON in the decoder's shape.
        let format = try dictionary(body["response_format"])
        try expect(format["type"] as? String == "json_schema", "a local Summary request constrains its JSON")
        let schema = try dictionary(try dictionary(format["json_schema"])["schema"])
        try expect(
            Set(try array(schema["required"]).compactMap { $0 as? String })
                == ["overview", "keyPoints", "decisions", "actionItems", "openQuestions"],
            "the schema requires every Summary key"
        )
        let actionItem = try dictionary(
            try dictionary(try dictionary(schema["properties"])["actionItems"])["items"]
        )
        try expect(
            Set(try array(actionItem["required"]).compactMap { $0 as? String })
                == ["task", "owner", "dueDate", "sourceQuote"],
            "an action item must carry its nullable owner and due date"
        )
        try expect(actionItem["additionalProperties"] as? Bool == false, "an action item allows no other keys")
        // llama-server makes the model write keys in schema order, so it
        // must be the prompt's order on every launch.
        let rawBody = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        guard let formatStart = rawBody.range(of: #""response_format":"#) else {
            throw MeetingSummaryServiceTestFailure("Missing response_format")
        }
        let rawFormat = String(rawBody[formatStart.upperBound...])
        func offsets(_ keys: [String], in text: String) -> [Int] {
            keys.map { key in
                text.range(of: "\"\(key)\":{").map {
                    text.distance(from: text.startIndex, to: $0.lowerBound)
                } ?? -1
            }
        }
        let summaryKeys = offsets(
            ["overview", "keyPoints", "decisions", "actionItems", "openQuestions"],
            in: rawFormat
        )
        try expect(!summaryKeys.contains(-1) && summaryKeys == summaryKeys.sorted(), "the schema lists Summary keys in prompt order")
        guard let actionStart = rawFormat.range(of: #""actionItems":"#) else {
            throw MeetingSummaryServiceTestFailure("Missing actionItems schema")
        }
        let actionKeys = offsets(
            ["task", "owner", "dueDate", "sourceQuote"],
            in: String(rawFormat[actionStart.upperBound...])
        )
        try expect(!actionKeys.contains(-1) && actionKeys == actionKeys.sorted(), "the schema lists action item keys in prompt order")
        try expect(body["max_tokens"] as? Int == ceiling, "local Summary sends the legacy completion key too")
    }

    private static func testUnknownTopLevelKeyIsRejected() throws {
        let invalid = validJSON.dropLast() + #", "unexpected": true}"#
        try expectFailure("unknown top-level key") {
            _ = try MeetingSummaryStrictDecoder.decode(String(invalid))
        }
    }

    private static func testOwnerAndDueDateMayBeNull() throws {
        let decoded = try MeetingSummaryStrictDecoder.decode(validJSON)
        try expect(decoded.actionItems.count == 1, "one action item")
        try expect(decoded.actionItems[0].owner == nil, "null owner")
        try expect(decoded.actionItems[0].dueDate == nil, "null due date")
    }

    /// The iPhone's small local model wraps overview quotes one level
    /// deeper; only the iPhone asks to unwrap them.
    private static func testNestedOverviewQuotesAreUnwrappedOnlyWhenAsked() throws {
        let nested = #"{"overview":{"text":"Release review","sourceQuotes":[["Release review."]]},"keyPoints":[],"decisions":[],"actionItems":[],"openQuestions":[]}"#
        try expectFailure("nested overview quotes without unwrapping") {
            _ = try MeetingSummaryStrictDecoder.decode(nested)
        }
        let decoded = try MeetingSummaryStrictDecoder.decode(
            nested,
            unwrapsNestedSourceQuotes: true
        )
        try expect(
            decoded.overview.sourceQuotes == ["Release review."],
            "one level of overview quotes is unwrapped"
        )
    }

    /// #643: when the extraction room isn't smaller than the merge room (the
    /// iPhone and Mac cloud summaries use one value for both), the compact merge pass can't
    /// fit anything new, so it isn't tried. The error is the same, with half
    /// the merge prompts counted.
    private static func testCompactMergeIsSkippedWithTheSameRoom() async throws {
        func run(extractionRoom: Int) async throws -> (error: MeetingSummaryError?, mergeCounts: Int) {
            let counter = MeetingSummaryMergeCountingTokenCounter()
            let budgeter = LocalAITokenBudgeter(
                contextWindow: 8_192,
                tokenCounter: counter,
                summaryCompletionTokens: extractionRoom,
                summaryMergeCompletionTokens: 2_048
            )
            var thrown: MeetingSummaryError?
            do {
                _ = try await MeetingSummaryGenerator(
                    requester: MeetingSummaryCountingRequester(),
                    tokenBudgeter: budgeter,
                    chunker: MeetingSummaryTextChunker(maximumSourceBytes: 16),
                    chunkSizing: .exactBytesPerToken
                ).generate(source: MeetingSummarySource(
                    transcript: "First line here.\n\nSecond line here.\n\nThird line here.",
                    calendar: nil,
                    languageContext: summaryLanguage
                ))
            } catch let error as MeetingSummaryError {
                thrown = error
            }
            return (thrown, counter.mergeCounts())
        }
        let sameRoom = try await run(extractionRoom: 2_048)
        let smallerRoom = try await run(extractionRoom: 1_024)
        try expect(sameRoom.error == .invalidResponse(.mergeBudget), "the same room still ends with mergeBudget")
        try expect(smallerRoom.error == .invalidResponse(.mergeBudget), "a smaller room tries the compact pass, then ends the same way")
        try expect(sameRoom.mergeCounts > 0, "merge prompts are counted")
        try expect(sameRoom.mergeCounts < smallerRoom.mergeCounts, "the same room skips the compact pass")
    }

    /// The 266-byte transcript counts as 140 tokens, about 1.9 bytes a
    /// token, with 40 tokens of source room. The Mac's whole-ratio sizing
    /// floors the ratio to 1 and cuts 20-byte chunks (40 * 1 / 2); the
    /// iPhone's exact sizing cuts 38-byte chunks (40 * 266 / 140 / 2).
    private static func testExactChunkSizingKeepsTheFractionalByteRatio() async throws {
        let transcript = (1...12).map { "Line \($0) of the review." }.joined(separator: "\n")
        func extractionCount(_ sizing: MeetingSummaryChunkSizing) async throws -> Int {
            let requester = MeetingSummaryCountingRequester()
            let budgeter = LocalAITokenBudgeter(
                // 40 tokens of source room after a 1,000-token prompt.
                contextWindow: 1_000 + 1_024 + LocalAITokenBudgeter.safetyMarginTokens + 40,
                tokenCounter: MeetingSummaryRatioTokenCounter()
            )
            _ = try await MeetingSummaryGenerator(
                requester: requester,
                tokenBudgeter: budgeter,
                chunkSizing: sizing
            ).generate(source: MeetingSummarySource(
                transcript: transcript,
                calendar: nil,
                languageContext: summaryLanguage
            ))
            return requester.extractionCount()
        }
        try expect(transcript.utf8.count == 266, "the transcript is 266 bytes")
        let whole = try await extractionCount(.wholeBytesPerToken)
        let exact = try await extractionCount(.exactBytesPerToken)
        try expect(
            whole == MeetingSummaryTextChunker(maximumSourceBytes: 20).chunks(for: transcript).count
                && whole == 24,
            "whole-ratio sizing cuts 20-byte chunks (got \(whole) extractions)"
        )
        try expect(
            exact == MeetingSummaryTextChunker(maximumSourceBytes: 38).chunks(for: transcript).count
                && exact == 12,
            "exact sizing cuts 38-byte chunks (got \(exact) extractions)"
        )
    }

    private static func testRateLimitUsesConfiguredFallback() async throws {
        let recorder = MeetingSummaryRequestRecorder()
        let service = makeCloudService(fallbackModel: "fallback/model") { request in
            recorder.record(request)
            let model = try string(try requestBody(request)["model"])
            if model == "primary/model" {
                return rateLimitedResponse(request: request)
            }
            return try successResponse(request: request, content: validJSON)
        }

        let start = Date(timeIntervalSince1970: 1_000)
        let calendar = MeetingSummaryCalendarContext(
            title: "Quarterly Planning",
            start: start,
            end: start.addingTimeInterval(1_800),
            attendees: ["Adaeze Okafor", "linnea@example.com"]
        )
        let result = try await service.generate(
            source: MeetingSummarySource(
                transcript: summaryTranscript,
                calendar: calendar,
                languageContext: summaryLanguage
            )
        )
        let models = try recorder.requests().map {
            try string(try requestBody($0)["model"])
        }

        try expect(models == ["primary/model", "fallback/model"], "fallback request order")
        try expect(result.modelID == "fallback/model", "fallback result model")
        // #529: the fallback cloud model doesn't get the calendar either.
        try expectNoCalendar(in: recorder.requests(), calendar: calendar)
    }

    private static func testRateLimitRetainsAllowlistedProviderCode() async throws {
        for testCase in [
            (providerCode: "rate_limit_exceeded", expectedCode: "rate_limit_exceeded"),
            (providerCode: "sk-secret-api-key", expectedCode: Optional<String>.none)
        ] {
            let service = makeCloudService { request in
                try providerErrorResponse(
                    request: request,
                    statusCode: 429,
                    code: testCase.providerCode
                )
            }

            do {
                _ = try await service.generate(
                    source: MeetingSummarySource(
                        transcript: summaryTranscript,
                        calendar: nil,
                        languageContext: summaryLanguage
                    )
                )
                throw MeetingSummaryServiceTestFailure("Expected rate limit")
            } catch let failure as MeetingSummaryServiceTestFailure {
                throw failure
            } catch let error as MeetingSummaryError {
                let issue = error.userIssue(
                    providerHost: "api.example.com",
                    modelID: "primary/model",
                    localBackend: nil
                )
                let attempt = MeetingSummaryAttempt(
                    occurredAt: Date(timeIntervalSince1970: 2_000),
                    outcome: .failed,
                    backendKind: .cloud,
                    modelID: "primary/model",
                    providerHost: "api.example.com",
                    language: nil,
                    issue: issue
                )
                let encoded = String(
                    data: try JSONEncoder().encode(attempt),
                    encoding: .utf8
                )!

                try expect(
                    issue.context.providerCode == testCase.expectedCode,
                    "429 preserves only an allowlisted provider code"
                )
                try expect(
                    issue.presentation().detailsRows.contains {
                        $0.label == "Provider code" && $0.value == testCase.expectedCode
                    } == (testCase.expectedCode != nil),
                    "429 Details preserve only an allowlisted provider code"
                )
                if let expectedCode = testCase.expectedCode {
                    try expect(
                        encoded.contains(expectedCode),
                        "429 attempt persists its allowlisted provider code"
                    )
                } else {
                    try expect(
                        !encoded.contains(testCase.providerCode),
                        "429 attempt excludes its unsafe provider code"
                    )
                }
            }
        }
    }

    private static func testFallbackTerminalFailureReportsPrimaryModel() async throws {
        let service = makeCloudService(fallbackModel: "fallback/model") { request in
            let model = try string(try requestBody(request)["model"])
            if model == "primary/model" {
                return rateLimitedResponse(request: request)
            }
            return try providerErrorResponse(
                request: request,
                statusCode: 503,
                code: "service_unavailable"
            )
        }

        do {
            _ = try await service.generate(
                source: MeetingSummarySource(
                    transcript: summaryTranscript,
                    calendar: nil,
                    languageContext: summaryLanguage
                )
            )
            throw MeetingSummaryServiceTestFailure("Expected fallback failure")
        } catch let failure as MeetingSummaryServiceTestFailure {
            throw failure
        } catch let error as MeetingSummaryError {
            let issue = error.userIssue(
                providerHost: "api.example.com",
                modelID: "primary/model",
                localBackend: nil
            )
            // When the fallback fails too, the primary's error is reported.
            try expect(
                issue.context.modelID == "primary/model",
                "terminal fallback failure reports the primary model's error"
            )
        }
    }

    private static func testTraditionalChineseSameAsSpokenUsesTraditionalPromptAndValidator() async throws {
        let sourceQuote = "團隊決定下週二發布產品，並在今天完成說明文件。"
        for engineLanguageCode in ["zh-Hant", "zh-HK"] {
            let spoken = SpokenLanguageResolver.resolve(
                requestedLanguageCode: "auto",
                engineLanguageCode: engineLanguageCode,
                transcript: sourceQuote
            )
            let source = MeetingSummarySource(
                transcript: sourceQuote,
                calendar: nil,
                languageContext: MeetingSummaryLanguageContext(
                    requestedOutputLanguage: "",
                    appliedLanguageCode: spoken.languageCode ?? "",
                    resolutionSource: spoken.source
                )
            )
            let traditionalJSON = #"{"overview":{"text":"團隊決定下週二發布產品。","sourceQuotes":["團隊決定下週二發布產品，並在今天完成說明文件。"]},"keyPoints":[],"decisions":[],"actionItems":[],"openQuestions":[]}"#
            let recorder = MeetingSummaryRequestRecorder()
            let service = makeCloudService { request in
                recorder.record(request)
                return try successResponse(request: request, content: traditionalJSON)
            }

            _ = try await service.generate(source: source)
            let messages = try array(try requestBody(try recorder.requests().only())["messages"])
            let system = try string(try dictionary(messages[0])["content"])
            try expect(
                spoken == SpokenLanguageResolution(
                    languageCode: "zh-Hant",
                    source: .engineDetected
                ),
                "Traditional Chinese engine result is preserved for \(engineLanguageCode)"
            )
            try expect(
                system.contains("Write generated summary prose in Traditional Chinese."),
                "Traditional Chinese Same-as-spoken uses a script-specific prompt"
            )
        }
    }

    private static func testLongTranscriptExtractsEveryChunkThenMerges() async throws {
        let recorder = MeetingSummaryRequestRecorder()
        let service = makeCloudService(
            chunker: MeetingSummaryTextChunker(maxCharacters: 35)
        ) { request in
            recorder.record(request)
            let user = try userMessage(request)
            if user.contains("validatedPartials") {
                return try successResponse(request: request, content: mergedJSON)
            }
            let content = user.contains("First paragraph")
                ? partialJSON
                : partialSecondJSON
            return try successResponse(request: request, content: content)
        }
        let transcript = [
            "First paragraph has a decision.",
            "Second paragraph has an action."
        ].joined(separator: "\n\n")

        _ = try await service.generate(
            source: MeetingSummarySource(
                transcript: transcript,
                calendar: nil,
                languageContext: summaryLanguage
            )
        )
        let requests = recorder.requests()

        try expect(requests.count == 3, "two extraction requests and one merge")
        let extractionPrompts = try requests.prefix(2).map(userMessage)
        try expect(extractionPrompts[0].contains("First paragraph"), "first chunk included")
        try expect(extractionPrompts[1].contains("Second paragraph"), "second chunk included")
        try expect(try userMessage(requests[2]).contains("validatedPartials"), "merge prompt")
    }

    private static func testHierarchyUsesBoundedIntermediateMergesAndCompletionCeiling() async throws {
        let recorder = MeetingSummaryRequestRecorder()
        let tokenCounter = MeetingSummaryRecordingTokenCounter()
        let budgeter = LocalAITokenBudgeter(
            contextWindow: 5_200,
            tokenCounter: tokenCounter
        )
        let service = makeCloudService(
            chunker: MeetingSummaryTextChunker(maximumSourceBytes: 24),
            tokenBudgeter: budgeter
        ) { request in
            recorder.record(request)
            return try successResponse(request: request, content: largeEvidenceJSON)
        }

        _ = try await service.generate(
            source: MeetingSummarySource(
                transcript: String(repeating: "Evidence line. ", count: 10),
                calendar: nil,
                languageContext: summaryLanguage
            )
        )

        let requests = recorder.requests()
        let mergeCount = try requests
            .map(userMessage)
            .filter { $0.contains("validatedPartials") }
            .count
        try expect(mergeCount >= 2, "long summaries use at least two bounded intermediate merge requests")
        for request in requests {
            let body = try requestBody(request)
            try expect(
                body["max_completion_tokens"] as? Int == 1_024,
                "every Summary request reserves the 1,024-token completion ceiling"
            )
        }
        for request in requests {
            let messages = try array(try requestBody(request)["messages"])
            let system = try string(try dictionary(messages[0])["content"])
            let user = try string(try dictionary(messages[1])["content"])
            let rendered = "[System]\n\(system)\n\n[User]\n\(user)"
            try expect(
                rendered.utf8.count + 1_024 + 512 <= 5_200,
                "every generated Summary request stays inside the injected context budget"
            )
        }
    }

    private static func testHierarchyCarriesSingletonTailIntoNextMergeRound() async throws {
        let recorder = MeetingSummaryRequestRecorder()
        let service = makeCloudService(
            chunker: MeetingSummaryTextChunker(maximumSourceBytes: 16),
            tokenBudgeter: LocalAITokenBudgeter(
                contextWindow: 2_000,
                tokenCounter: SingletonTailTokenCounter()
            )
        ) { request in
            recorder.record(request)
            return try successResponse(request: request, content: largeEvidenceJSON)
        }

        _ = try await service.generate(
            source: MeetingSummarySource(
                transcript: "Evidence line.\n\nEvidence line.\n\nEvidence line.",
                calendar: nil,
                languageContext: summaryLanguage
            )
        )

        let mergeRequests = try recorder.requests().filter {
            try userMessage($0).contains("validatedPartials")
        }
        try expect(
            recorder.requests().count == 5,
            "three extractions, one intermediate merge, and one final merge"
        )
        try expect(mergeRequests.count == 2, "singleton tails do not create merge requests")
    }

    private static func testUnresolvedCitationReturnsUnverifiedSummaryWithoutExtraModelCall() async throws {
        let recorder = MeetingSummaryRequestRecorder()
        let service = makeCloudService { request in
            recorder.record(request)
            return try successResponse(
                request: request,
                content: #"{"overview":{"text":"Release review","sourceQuotes":["Invented citation."]},"keyPoints":[],"decisions":[],"actionItems":[],"openQuestions":[]}"#
            )
        }

        let result = try await service.generate(
            source: MeetingSummarySource(
                transcript: summaryTranscript,
                calendar: nil,
                languageContext: summaryLanguage
            )
        )

        try expect(
            result.evidenceVerification == .unverified,
            "unresolved citation saves an unverified summary instead of a hard failure"
        )
        try expect(
            recorder.requests().count == 1,
            "unresolved citation does not cause an extra model call"
        )
    }

    private static func testMissingCitationReturnsUnverifiedSummary() async throws {
        let service = makeCloudService { request in
            try successResponse(
                request: request,
                content: #"{"overview":{"text":"Release review","sourceQuotes":[]},"keyPoints":[],"decisions":[],"actionItems":[],"openQuestions":[]}"#
            )
        }

        let result = try await service.generate(
            source: MeetingSummarySource(
                transcript: summaryTranscript,
                calendar: nil,
                languageContext: summaryLanguage
            )
        )

        try expect(
            result.evidenceVerification == .unverified,
            "missing citations are saved as unverified evidence instead of a schema failure"
        )
    }

    private static func testNullPointCitationReturnsUnverifiedSummary() async throws {
        let service = makeCloudService { request in
            try successResponse(
                request: request,
                content: #"{"overview":{"text":"Release review","sourceQuotes":["Release review."]},"keyPoints":[{"text":"Launch remains on schedule.","sourceQuote":null}],"decisions":[],"actionItems":[],"openQuestions":[]}"#
            )
        }

        let result = try await service.generate(
            source: MeetingSummarySource(
                transcript: summaryTranscript,
                calendar: nil,
                languageContext: summaryLanguage
            )
        )

        try expect(
            result.evidenceVerification == .unverified,
            "missing point citations are saved as unverified evidence instead of a schema failure"
        )
    }

    private static func testNullOverviewCitationReturnsUnverifiedSummary() async throws {
        let service = makeCloudService { request in
            try successResponse(
                request: request,
                content: #"{"overview":{"text":"Release review","sourceQuotes":[null]},"keyPoints":[],"decisions":[],"actionItems":[],"openQuestions":[]}"#
            )
        }

        let result = try await service.generate(
            source: MeetingSummarySource(
                transcript: summaryTranscript,
                calendar: nil,
                languageContext: summaryLanguage
            )
        )

        try expect(
            result.evidenceVerification == .unverified,
            "missing overview citations are saved as unverified evidence instead of a schema failure"
        )
    }

    private static func testChunkFailureDoesNotReturnPartialSummary() async throws {
        let requestCount = MeetingSummaryRequestRecorder()
        let service = makeCloudService(
            chunker: MeetingSummaryTextChunker(maxCharacters: 35)
        ) { request in
            requestCount.record(request)
            if requestCount.requests().count == 2 {
                return try successResponse(request: request, content: #"{"overview":""}"#)
            }
            return try successResponse(request: request, content: partialJSON)
        }
        let transcript = [
            "First paragraph has a decision.",
            "Second paragraph has an action."
        ].joined(separator: "\n\n")

        do {
            _ = try await service.generate(
                source: MeetingSummarySource(
                transcript: transcript,
                calendar: nil,
                languageContext: summaryLanguage
            )
            )
            throw MeetingSummaryServiceTestFailure("Expected chunk failure")
        } catch let failure as MeetingSummaryServiceTestFailure {
            throw failure
        } catch {
            try expect(requestCount.requests().count == 2, "merge not attempted after chunk failure")
        }
    }

    /// A response cut off at the token limit is not reported as a bad
    /// format (#609).
    private static func testTruncatedResponseReportsOutputTruncated() async throws {
        // Cut off mid-JSON, or with no content when reasoning used it all.
        let messages: [Any] = [
            ["content": String(validJSON.prefix(40))],
            ["content": NSNull()]
        ]
        for message in messages {
            let service = makeCloudService { request in
                let data = try JSONSerialization.data(withJSONObject: [
                    "choices": [["message": message, "finish_reason": "length"]]
                ])
                return (
                    data,
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                )
            }

            do {
                _ = try await service.generate(source: fallbackSource())
                throw MeetingSummaryServiceTestFailure("Expected truncated response failure")
            } catch let failure as MeetingSummaryServiceTestFailure {
                throw failure
            } catch MeetingSummaryError.invalidResponse(let subtype, _) {
                try expect(subtype == .outputTruncated, "a length-limited response reports outputTruncated")
            }
        }
    }

    /// A local model's prompt is counted by its own tokenizer, and the
    /// response gets all the context the prompt leaves (#609).
    private static func testLocalSummaryCountsTokensWithLocalServer() async throws {
        let recorder = MeetingSummaryRequestRecorder()
        let service = MeetingSummaryService(
            backendExecutor: makeLocalExecutor(),
            fallbackExecutor: nil,
            transport: { request in
                recorder.record(request)
                if request.url?.path == "/tokenize" {
                    // Four bytes to a token, as for a Korean transcript.
                    let body = try requestBody(request)
                    let content = try string(body["content"])
                    let tokens = Array(repeating: 1, count: content.utf8.count / 4)
                    return (
                        try JSONSerialization.data(withJSONObject: ["tokens": tokens]),
                        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                    )
                }
                return try successResponse(request: request, content: validJSON)
            }
        )

        _ = try await service.generate(source: fallbackSource())

        let tokenize = recorder.allRequests().filter { $0.url?.path == "/tokenize" }
        try expect(!tokenize.isEmpty, "the local server counts the prompt's tokens")
        try expect(
            tokenize.allSatisfy { $0.url?.host == "127.0.0.1" },
            "token counting stays on this Mac"
        )
        let request = try recorder.requests().only()
        let body = try requestBody(request)
        let messages = try array(body["messages"])
        let system = try string(try dictionary(messages[0])["content"])
        let user = try string(try dictionary(messages[1])["content"])
        let promptTokens = "[System]\n\(system)\n\n[User]\n\(user)".utf8.count / 4
        try expect(
            body["max_completion_tokens"] as? Int == min(16_384 - promptTokens - 512, 6_144),
            "the response may use the context the prompt leaves, up to 6,144 tokens"
        )
    }

    /// A local merge batch leaves the full 6,144-token response room, so a
    /// long meeting's merge isn't cut off (#610).
    private static func testLocalMergeLeavesTheFullResponseRoom() async throws {
        // Three partials fit beside a 4,096-token response but not a
        // 6,144-token one.
        let recorder = MeetingSummaryRequestRecorder()
        let service = makeLocalMergeService(tokensPerPartial: 3_000, chunks: 3, recorder: recorder)

        _ = try await service.generate(source: localMergeSource(chunks: 3))

        let merges = try recorder.requests().filter {
            try userMessage($0).contains("validatedPartials")
        }
        try expect(merges.count == 2, "three partials merge in two steps")
        for merge in merges {
            try expect(partialCount(in: try userMessage(merge)) <= 2, "a merge batch leaves the full response room")
            try expect(
                try requestBody(merge)["max_completion_tokens"] as? Int == 6_144,
                "a local merge may write up to 6,144 tokens"
            )
        }
    }

    /// Two partials too large to merge beside the full room still merge
    /// beside the extraction room, as before #610.
    private static func testLocalMergeFallsBackToTheExtractionRoom() async throws {
        let recorder = MeetingSummaryRequestRecorder()
        let service = makeLocalMergeService(tokensPerPartial: 5_000, chunks: 2, recorder: recorder)

        _ = try await service.generate(source: localMergeSource(chunks: 2))

        let merge = try recorder.requests().filter {
            try userMessage($0).contains("validatedPartials")
        }.only()
        try expect(partialCount(in: try userMessage(merge)) == 2, "both partials merge at once")
        try expect(
            try requestBody(merge)["max_completion_tokens"] as? Int == 16_384 - 11_000 - 512,
            "the merge uses the context the prompt leaves"
        )
    }

    /// Partials appear in a merge prompt as compact JSON; the system
    /// prompt's shape has a space after each colon.
    private static func partialCount(in prompt: String) -> Int {
        prompt.components(separatedBy: #""sourceQuotes":["#).count - 1
    }

    private static func localMergeSource(chunks: Int) -> MeetingSummarySource {
        MeetingSummarySource(
            transcript: Array(repeating: "Evidence line.", count: chunks).joined(separator: "\n\n"),
            calendar: nil,
            languageContext: summaryLanguage
        )
    }

    /// A local service whose server counts 1,000 tokens a prompt plus
    /// `tokensPerPartial` for each partial it carries.
    private static func makeLocalMergeService(
        tokensPerPartial: Int,
        chunks: Int,
        recorder: MeetingSummaryRequestRecorder
    ) -> MeetingSummaryService {
        MeetingSummaryService(
            backendExecutor: makeLocalExecutor(),
            fallbackExecutor: nil,
            chunker: MeetingSummaryTextChunker(maximumSourceBytes: 16),
            transport: { request in
                recorder.record(request)
                if request.url?.path == "/tokenize" {
                    let content = try string(try requestBody(request)["content"])
                    let tokens = Array(
                        repeating: 1,
                        count: 1_000 + tokensPerPartial * partialCount(in: content)
                    )
                    return (
                        try JSONSerialization.data(withJSONObject: ["tokens": tokens]),
                        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                    )
                }
                return try successResponse(request: request, content: largeEvidenceJSON)
            }
        )
    }

    /// A model copies the partials' shape, so they carry every response
    /// key, null included, and nothing else (#612).
    private static func testMergePromptUsesSummaryResponseShape() throws {
        let partial = try MeetingSummaryStrictDecoder.decode(validJSON)
        let prompt = try MeetingSummaryPromptFactory.merge(
            validatedPartials: [partial],
            outputLanguage: "English"
        )
        guard let start = prompt.user.firstIndex(of: "{") else {
            throw MeetingSummaryServiceTestFailure("Missing merge envelope")
        }
        let envelope = try dictionary(
            try JSONSerialization.jsonObject(with: Data(prompt.user[start...].utf8))
        )
        let data = try dictionary(envelope["data"])
        let encoded = try dictionary(try array(data["validatedPartials"]).only())

        try expect(
            Set(encoded.keys) == ["overview", "keyPoints", "decisions", "actionItems", "openQuestions"],
            "a merge partial has only the response's top-level keys"
        )
        let action = try dictionary(try array(encoded["actionItems"]).only())
        try expect(
            Set(action.keys) == ["task", "owner", "dueDate", "sourceQuote"],
            "an action item keeps its null owner and due date, without app-only fields"
        )
        try expect(action["owner"] is NSNull, "a missing owner is written as null")
        try expect(action["dueDate"] is NSNull, "a missing due date is written as null")
        let point = try dictionary(try array(encoded["keyPoints"]).only())
        try expect(Set(point.keys) == ["text", "sourceQuote"], "a point has only its response keys")
        // The response decoder accepts the merge input's own shape.
        let reencoded = String(
            data: try JSONSerialization.data(withJSONObject: encoded),
            encoding: .utf8
        )!
        _ = try MeetingSummaryStrictDecoder.decode(reencoded)
    }

    /// A small local model can drift into Chinese mid-summary, so prose in a
    /// language that doesn't write Han can't contain it; quotes stay as
    /// spoken (#613).
    private static func testLocalSchemaKeepsHanOutOfProseUnlessTheLanguageWritesIt() async throws {
        for (code, excludesHan) in [("ko", true), ("en", true), ("ja", false), ("zh-Hant", false)] {
            let recorder = MeetingSummaryRequestRecorder()
            let service = MeetingSummaryService(
                backendExecutor: makeLocalExecutor(),
                fallbackExecutor: nil,
                chunker: MeetingSummaryTextChunker(maxCharacters: 35),
                transport: { request in
                    recorder.record(request)
                    let user = (try? userMessage(request)) ?? ""
                    if user.contains("validatedPartials") {
                        return try successResponse(request: request, content: mergedJSON)
                    }
                    let content = user.contains("First paragraph")
                        ? partialJSON
                        : partialSecondJSON
                    return try successResponse(request: request, content: content)
                }
            )
            // Only the requests matter; the English fixtures fail the
            // language check for other languages before the merge.
            _ = try? await service.generate(
                source: MeetingSummarySource(
                    transcript: [
                        "First paragraph has a decision.",
                        "Second paragraph has an action."
                    ].joined(separator: "\n\n"),
                    calendar: nil,
                    languageContext: MeetingSummaryLanguageContext(
                        requestedOutputLanguage: code,
                        appliedLanguageCode: code,
                        resolutionSource: .configured
                    )
                )
            )

            let requests = recorder.requests()
            try expect(!requests.isEmpty, "\(code) summary request")
            if code == "en" {
                try expect(
                    try userMessage(try requests.last.unwrap("merge request")).contains("validatedPartials"),
                    "the merge request is checked too"
                )
            }
            for request in requests {
                let body = try requestBody(request)
                let schema = try dictionary(
                    try dictionary(try dictionary(body["response_format"])["json_schema"])["schema"]
                )
                let properties = try dictionary(schema["properties"])
                let overview = try dictionary(try dictionary(properties["overview"])["properties"])
                let point = try dictionary(
                    try dictionary(try dictionary(properties["keyPoints"])["items"])["properties"]
                )
                let action = try dictionary(
                    try dictionary(try dictionary(properties["actionItems"])["items"])["properties"]
                )
                for (label, field) in [
                    ("overview text", overview["text"]),
                    ("point text", point["text"]),
                    ("action task", action["task"])
                ] {
                    let pattern = try dictionary(field)["pattern"] as? String
                    if excludesHan {
                        let pattern = try pattern.unwrap("\(code) \(label) pattern")
                        let regex = try NSRegularExpression(pattern: pattern)
                        // The pattern sees the raw JSON text inside the quotes.
                        func matches(_ text: String) -> Bool {
                            regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
                        }
                        try expect(matches("다음 주 월요일까지 공유"), "\(code) \(label) allows Hangul")
                        try expect(!matches("回顾会议"), "\(code) \(label) excludes Han")
                        try expect(matches(#"이름은 \"새벽\"으로"#), "\(code) \(label) allows an escaped quote")
                        try expect(matches(#"A\\B\nC"#), "\(code) \(label) allows other escapes")
                        try expect(!matches(#"say "done"#), "\(code) \(label) keeps a bare quote out")
                        try expect(!matches(#"path \q"#), "\(code) \(label) keeps a bare backslash out")
                    } else {
                        try expect(pattern == nil, "\(code) \(label) may write Han")
                    }
                }
                try expect(try dictionary(point["sourceQuote"])["pattern"] == nil, "\(code) quotes stay unconstrained")
                try expect(
                    try dictionary(try dictionary(overview["sourceQuotes"])["items"])["pattern"] == nil,
                    "\(code) overview quotes stay unconstrained"
                )
            }
        }
    }

    // MARK: - Fallback triggers (#580)

    private static let fallbackCalendar = MeetingSummaryCalendarContext(
        title: "Roadmap Sync",
        start: Date(timeIntervalSince1970: 1_000),
        end: Date(timeIntervalSince1970: 2_800),
        attendees: ["Ines Varga", "kofi@example.com"]
    )

    private static func fallbackSource(
        calendar: MeetingSummaryCalendarContext? = nil
    ) -> MeetingSummarySource {
        MeetingSummarySource(
            transcript: summaryTranscript,
            calendar: calendar,
            languageContext: summaryLanguage
        )
    }

    private static func makeLocalExecutor(
        localAIAvailability: LocalAIProcessingAvailability = LocalAIProcessingAvailability(
            isAppleSilicon: true,
            runnerIsExecutable: true,
            physicalMemory: 16 * 1024 * 1024 * 1024
        )
    ) -> AIProcessingBackendExecutor {
        let process = MeetingSummaryFakeProcess()
        let manager = LocalAIServerManager(
            launchProcess: { _, _, port, _ in (process, port) },
            pollHealth: { _ in true },
            readinessProbe: successfulReadinessProbe,
            validateModel: { _ in .ready }
        )
        return AIProcessingBackendExecutor(
            choice: .localAI(modelID: LocalAIModelCatalog.quality.id),
            cloudBaseURL: "https://api.example.com/openai/v1/\(UUID().uuidString)",
            cloudAPIKey: "test-key",
            localServerManager: manager,
            localAIAvailability: localAIAvailability
        )
    }

    private static func requestModels(_ recorder: MeetingSummaryRequestRecorder) throws -> [String] {
        try recorder.requests().map { try string(try requestBody($0)["model"]) }
    }

    private static func testCloudFallbackRunsOnServerErrorButNotNetworkFailure() async throws {
        let recorder = MeetingSummaryRequestRecorder()
        let service = makeCloudService(fallbackModel: "fallback/model") { request in
            recorder.record(request)
            if try string(try requestBody(request)["model"]) == "primary/model" {
                return try providerErrorResponse(request: request, statusCode: 502, code: "bad_gateway")
            }
            return try successResponse(request: request, content: validJSON)
        }
        let result = try await service.generate(source: fallbackSource())
        let models = try requestModels(recorder)
        try expect(models == ["primary/model", "fallback/model"], "5xx: fallback order")
        try expect(result.modelID == "fallback/model", "5xx: fallback result model")

        // Offline or timed out: no cloud-to-cloud retry, a local one runs.
        let failures: [(String, @Sendable (URLRequest) throws -> (Data, URLResponse))] = [
            ("offline", { _ in throw URLError(.notConnectedToInternet) }),
            ("timeout", { _ in throw URLError(.timedOut) })
        ]
        for (label, failure) in failures {
            let cloudRecorder = MeetingSummaryRequestRecorder()
            let cloud = makeCloudService(fallbackModel: "fallback/model") { request in
                cloudRecorder.record(request)
                return try failure(request)
            }
            do {
                _ = try await cloud.generate(source: fallbackSource())
                throw MeetingSummaryServiceTestFailure("\(label): expected failure")
            } catch let failure as MeetingSummaryServiceTestFailure {
                throw failure
            } catch {}
            try expect(cloudRecorder.requests().count == 1, "\(label): no cloud-to-cloud retry")

            let localRecorder = MeetingSummaryRequestRecorder()
            let local = makeCloudService(fallbackExecutor: makeLocalExecutor()) { request in
                localRecorder.record(request)
                if request.url?.host == "127.0.0.1" {
                    return try successResponse(request: request, content: validJSON)
                }
                return try failure(request)
            }
            let localResult = try await local.generate(source: fallbackSource())
            try expect(localResult.backendKind == .local, "\(label): the local fallback runs")
        }
    }

    private static func testFailedSummaryFallbackReportsPrimaryError() async throws {
        let local = makeLocalExecutor(
            localAIAvailability: LocalAIProcessingAvailability(
                isAppleSilicon: false,
                runnerIsExecutable: false
            )
        )
        let service = MeetingSummaryService(
            backendExecutor: local,
            fallbackExecutor: local.replacingChoice(.cloud(modelID: "cloud/fallback")),
            transport: { request in
                try providerErrorResponse(request: request, statusCode: 503, code: "unavailable")
            }
        )
        do {
            _ = try await service.generate(source: fallbackSource())
            throw MeetingSummaryServiceTestFailure("Expected both models to fail")
        } catch let error as AIProcessingBackendError {
            try expect(
                error == .localRuntimeUnavailable(LocalAIModelCatalog.quality.id),
                "the local primary's failure is reported, not the fallback's"
            )
        }
    }

    private static func testCloudPrimaryFallsBackToLocalModel() async throws {
        let recorder = MeetingSummaryRequestRecorder()
        let service = makeCloudService(fallbackExecutor: makeLocalExecutor()) { request in
            recorder.record(request)
            if request.url?.host == "127.0.0.1" {
                return try successResponse(request: request, content: validJSON)
            }
            throw URLError(.cannotConnectToHost)
        }

        let result = try await service.generate(source: fallbackSource(calendar: fallbackCalendar))

        let hosts = recorder.requests().map { $0.url?.host }
        try expect(hosts == ["api.example.com", "127.0.0.1"], "cloud first, then the local fallback")
        try expect(result.backendKind == .local, "the summary comes from the local fallback")
        try expect(result.providerHost == nil, "a local summary has no provider host")
        try expect(result.modelID == LocalAIModelCatalog.quality.id, "local fallback model")
        try expectNoCalendar(in: [recorder.requests()[0]], calendar: fallbackCalendar)
    }

    private static func testLocalPrimaryFallsBackToCloudWithoutCalendar() async throws {
        let recorder = MeetingSummaryRequestRecorder()
        let local = makeLocalExecutor(
            localAIAvailability: LocalAIProcessingAvailability(
                isAppleSilicon: false,
                runnerIsExecutable: false
            )
        )
        let service = MeetingSummaryService(
            backendExecutor: local,
            fallbackExecutor: local.replacingChoice(.cloud(modelID: "cloud/fallback")),
            transport: { request in
                recorder.record(request)
                return try successResponse(request: request, content: validJSON)
            }
        )

        let result = try await service.generate(source: fallbackSource(calendar: fallbackCalendar))

        let models = try requestModels(recorder)
        try expect(models == ["cloud/fallback"], "the cloud fallback runs once")
        try expect(result.backendKind == .cloud, "the summary comes from the cloud fallback")
        try expect(result.providerHost == "api.example.com", "the result names the fallback's host")
        try expect(
            recorder.requests().allSatisfy { $0.url?.host == "api.example.com" },
            "the fallback uses the cloud base URL"
        )
        // #529: a cloud fallback never gets the calendar event either.
        try expectNoCalendar(in: recorder.requests(), calendar: fallbackCalendar)
    }

    private static func testLocalPrimaryWithoutFallbackNeverCallsCloud() async throws {
        let recorder = MeetingSummaryRequestRecorder()
        let service = MeetingSummaryService(
            backendExecutor: makeLocalExecutor(),
            fallbackExecutor: nil,
            transport: { request in
                recorder.record(request)
                if request.url?.host == "127.0.0.1" {
                    throw URLError(.networkConnectionLost)
                }
                throw MeetingSummaryServiceTestFailure("A cloud request was made")
            }
        )

        do {
            _ = try await service.generate(source: fallbackSource(calendar: fallbackCalendar))
            throw MeetingSummaryServiceTestFailure("Expected the local failure")
        } catch let failure as MeetingSummaryServiceTestFailure {
            throw failure
        } catch {}
        let hosts = recorder.requests().map { $0.url?.host }
        try expect(hosts == ["127.0.0.1"], "a local summary without a fallback stays on this Mac")
    }

    private static func testCancelledSummaryNeverFallsBack() async throws {
        let recorder = MeetingSummaryRequestRecorder()
        let local = makeLocalExecutor()
        let service = MeetingSummaryService(
            backendExecutor: local,
            fallbackExecutor: local.replacingChoice(.cloud(modelID: "cloud/fallback")),
            transport: { request in
                recorder.record(request)
                throw CancellationError()
            }
        )

        do {
            _ = try await service.generate(source: fallbackSource())
            throw MeetingSummaryServiceTestFailure("Expected cancellation")
        } catch let failure as MeetingSummaryServiceTestFailure {
            throw failure
        } catch {
            try expect(error is CancellationError, "the cancellation is reported as is")
        }
        let hosts = recorder.allRequests().map { $0.url?.host }
        try expect(
            !hosts.isEmpty && hosts.allSatisfy { $0 == "127.0.0.1" },
            "a cancelled summary is not retried"
        )
    }

    private static func testSummaryFallbackEqualToPrimaryIsNotRetried() async throws {
        let recorder = MeetingSummaryRequestRecorder()
        let service = makeCloudService(fallbackModel: "primary/model") { request in
            recorder.record(request)
            return try providerErrorResponse(request: request, statusCode: 503, code: "unavailable")
        }

        do {
            _ = try await service.generate(source: fallbackSource())
            throw MeetingSummaryServiceTestFailure("Expected the server error")
        } catch let failure as MeetingSummaryServiceTestFailure {
            throw failure
        } catch {}
        try expect(recorder.requests().count == 1, "the same model is not retried")
    }

    private static func makeCloudService(
        fallbackModel: String? = nil,
        fallbackExecutor: AIProcessingBackendExecutor? = nil,
        chunker: MeetingSummaryTextChunker = MeetingSummaryTextChunker(),
        tokenBudgeter: LocalAITokenBudgeter? = nil,
        transport: @escaping MeetingSummaryService.Transport
    ) -> MeetingSummaryService {
        let baseURL = "https://api.example.com/openai/v1/\(UUID().uuidString)"
        let primary = AIProcessingBackendExecutor(
            choice: .cloud(modelID: "primary/model"),
            cloudBaseURL: baseURL,
            cloudAPIKey: "test-key"
        )
        return MeetingSummaryService(
            backendExecutor: primary,
            fallbackExecutor: fallbackExecutor
                ?? fallbackModel.map { primary.replacingChoice(.cloud(modelID: $0)) },
            chunker: chunker,
            tokenBudgeter: tokenBudgeter,
            transport: transport
        )
    }

    /// No part of the calendar event: title, attendees, or the object
    /// that carries its times.
    private static func expectNoCalendar(in requests: [URLRequest], calendar: MeetingSummaryCalendarContext) throws {
        for request in requests {
            let requestText = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            try expect(!requestText.contains(calendar.title), "a cloud request leaves the calendar title out")
            for attendee in calendar.attendees {
                try expect(!requestText.contains(attendee), "a cloud request leaves attendees out")
            }
            try expect(!requestText.contains("\\\"calendar\\\":{"), "a cloud request has no calendar object")
        }
    }

    private static func userMessage(_ request: URLRequest) throws -> String {
        let messages = try array(try requestBody(request)["messages"])
        return try string(try dictionary(messages[1])["content"])
    }

    private static func requestBody(_ request: URLRequest) throws -> [String: Any] {
        guard let data = request.httpBody,
              let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MeetingSummaryServiceTestFailure("Invalid request body")
        }
        return body
    }

    private static func successResponse(
        request: URLRequest,
        content: String
    ) throws -> (Data, URLResponse) {
        let data = try JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["content": content]]]
        ])
        return (
            data,
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
        )
    }

    private static func providerErrorResponse(
        request: URLRequest,
        statusCode: Int,
        code: String
    ) throws -> (Data, URLResponse) {
        let data = try JSONSerialization.data(withJSONObject: [
            "error": [
                "code": code,
                "message": "provider response body"
            ]
        ])
        return (
            data,
            HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
        )
    }

    private static func rateLimitedResponse(
        request: URLRequest
    ) -> (Data, URLResponse) {
        (
            Data(#"{"error":{"code":"rate_limit"}}"#.utf8),
            HTTPURLResponse(
                url: request.url!,
                statusCode: 429,
                httpVersion: nil,
                headerFields: ["Retry-After": "1"]
            )!
        )
    }

    private static func expectFailure(
        _ label: String,
        operation: () throws -> Void
    ) throws {
        do {
            try operation()
            throw MeetingSummaryServiceTestFailure("Expected \(label)")
        } catch let failure as MeetingSummaryServiceTestFailure {
            throw failure
        } catch {}
    }

    private static func expect(
        _ condition: @autoclosure () throws -> Bool,
        _ label: String
    ) throws {
        guard try condition() else {
            throw MeetingSummaryServiceTestFailure(label)
        }
    }

    private static func dictionary(_ value: Any?) throws -> [String: Any] {
        guard let value = value as? [String: Any] else {
            throw MeetingSummaryServiceTestFailure("Expected dictionary")
        }
        return value
    }

    private static func array(_ value: Any?) throws -> [Any] {
        guard let value = value as? [Any] else {
            throw MeetingSummaryServiceTestFailure("Expected array")
        }
        return value
    }

    private static func int(_ value: Any?) throws -> Int {
        guard let value = value as? Int else {
            throw MeetingSummaryServiceTestFailure("Expected integer")
        }
        return value
    }

    private static func string(_ value: Any?) throws -> String {
        guard let value = value as? String else {
            throw MeetingSummaryServiceTestFailure("Expected string")
        }
        return value
    }

    private static let summaryTranscript = "Release review. Launch remains on schedule. Decision: ship Friday. Write release notes."

    private static let validJSON = #"{"overview":{"text":"Release review","sourceQuotes":["Release review."]},"keyPoints":[{"text":"Launch remains on schedule.","sourceQuote":"Launch remains on schedule."}],"decisions":[{"text":"Ship Friday.","sourceQuote":"Decision: ship Friday."}],"actionItems":[{"task":"Write release notes","owner":null,"dueDate":null,"sourceQuote":"Write release notes."}],"openQuestions":[]}"#

    private static let partialJSON = #"{"overview":{"text":"Chunk findings","sourceQuotes":["First paragraph has a decision."]},"keyPoints":[],"decisions":[],"actionItems":[],"openQuestions":[]}"#
    private static let partialSecondJSON = #"{"overview":{"text":"Chunk findings","sourceQuotes":["Second paragraph has an action."]},"keyPoints":[],"decisions":[],"actionItems":[],"openQuestions":[]}"#
    private static let mergedJSON = #"{"overview":{"text":"Merged review","sourceQuotes":["First paragraph has a decision."]},"keyPoints":[],"decisions":[],"actionItems":[],"openQuestions":[]}"#
    private static let largeEvidenceJSON = #"{"overview":{"text":"The team reviewed the evidence and recorded the agreed release plan. The team reviewed the evidence and recorded the agreed release plan. The team reviewed the evidence and recorded the agreed release plan. The team reviewed the evidence and recorded the agreed release plan. The team reviewed the evidence and recorded the agreed release plan. The team reviewed the evidence and recorded the agreed release plan.","sourceQuotes":["Evidence line."]},"keyPoints":[],"decisions":[],"actionItems":[],"openQuestions":[]}"#
}

private struct SingletonTailTokenCounter: LocalAITokenCounting {
    func tokenCount(forRenderedChatPrompt prompt: String) async throws -> Int {
        let evidenceCount = prompt.components(separatedBy: "Evidence line.").count - 1
        return evidenceCount >= 3 ? 465 : 1
    }
}

private actor MeetingSummaryRecordingTokenCounter: LocalAITokenCounting {
    private(set) var prompts: [String] = []

    func tokenCount(forRenderedChatPrompt prompt: String) async throws -> Int {
        prompts.append(prompt)
        return prompt.utf8.count
    }
}

private final class MeetingSummaryRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequests: [URLRequest] = []

    func record(_ request: URLRequest) {
        lock.lock()
        storedRequests.append(request)
        lock.unlock()
    }

    /// Summary requests, without a local model's token counting.
    func requests() -> [URLRequest] {
        allRequests().filter { $0.url?.path != "/tokenize" }
    }

    func allRequests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storedRequests
    }
}

private extension Optional {
    func unwrap(_ label: String) throws -> Wrapped {
        guard let self else { throw MeetingSummaryServiceTestFailure("Missing \(label)") }
        return self
    }
}

private extension Array {
    func only() throws -> Element {
        guard count == 1, let first else {
            throw MeetingSummaryServiceTestFailure("Expected one element")
        }
        return first
    }
}

/// Counts every prompt as small except merge prompts, which never fit, and
/// counts how many merge prompts were measured.
private final class MeetingSummaryMergeCountingTokenCounter: LocalAITokenCounting, @unchecked Sendable {
    private let lock = NSLock()
    private var merges = 0

    func tokenCount(forRenderedChatPrompt prompt: String) async throws -> Int {
        guard prompt.contains("validatedPartials") else { return 100 }
        lock.withLock { merges += 1 }
        return 100_000
    }

    func mergeCounts() -> Int { lock.withLock { merges } }
}

/// Counts a rendered prompt as 1,000 tokens and other text at about 1.9
/// bytes a token.
private struct MeetingSummaryRatioTokenCounter: LocalAITokenCounting {
    func tokenCount(forRenderedChatPrompt prompt: String) async throws -> Int {
        prompt.hasPrefix("[System]") ? 1_000 : prompt.utf8.count * 10 / 19
    }
}

private final class MeetingSummaryCountingRequester: MeetingSummaryDraftRequesting, @unchecked Sendable {
    private let lock = NSLock()
    private var extractions = 0

    var backendKind: MeetingSummaryBackendKind { .local }

    func requestDraft(
        _ request: MeetingSummaryDraftRequest
    ) async throws -> MeetingSummaryDraftReply {
        if case .summaryExtraction = request.role {
            recordExtraction()
        }
        return MeetingSummaryDraftReply(
            draft: MeetingSummaryDraftContentV2(
                overview: MeetingSummaryEvidenceText(text: "The team reviewed the lines.", sourceQuotes: []),
                keyPoints: [],
                decisions: [],
                actionItems: [],
                openQuestions: []
            ),
            modelID: "counting/model",
            backendKind: .local
        )
    }

    private func recordExtraction() {
        lock.lock()
        extractions += 1
        lock.unlock()
    }

    func extractionCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return extractions
    }
}

private final class MeetingSummaryFakeProcess: LocalAIServerProcess, @unchecked Sendable {
    private let lock = NSLock()
    private var running = true

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    func terminate() {
        lock.lock()
        running = false
        lock.unlock()
    }

    func forceTerminate() {
        terminate()
    }

    func setTerminationHandler(_ handler: @escaping () -> Void) {}
}

private struct MeetingSummaryServiceTestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
