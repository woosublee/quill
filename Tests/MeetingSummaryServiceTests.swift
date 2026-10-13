import Foundation

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
        try testUnknownTopLevelKeyIsRejected()
        try testOwnerAndDueDateMayBeNull()
        try await testRateLimitUsesConfiguredFallback()
        try await testRateLimitRetainsAllowlistedProviderCode()
        try await testFallbackTerminalFailureReportsFallbackModel()
        try await testTraditionalChineseSameAsSpokenUsesTraditionalPromptAndValidator()
        try await testLongTranscriptExtractsEveryChunkThenMerges()
        try await testHierarchyUsesBoundedIntermediateMergesAndCompletionCeiling()
        try await testHierarchyCarriesSingletonTailIntoNextMergeRound()
        try await testUnresolvedCitationReturnsUnverifiedSummaryWithoutExtraModelCall()
        try await testMissingCitationReturnsUnverifiedSummary()
        try await testNullPointCitationReturnsUnverifiedSummary()
        try await testNullOverviewCitationReturnsUnverifiedSummary()
        try await testChunkFailureDoesNotReturnPartialSummary()
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
        try expectNoCalendar(in: recorder.requests(), title: "Product Weekly")
        try expect(body["max_tokens"] == nil, "cloud Summary omits the local legacy completion key")
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
            cloudFallbackModelID: "cloud/fallback",
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
        try expect(
            body["max_completion_tokens"] as? Int == 1_024,
            "local Summary retains the 1,024-token completion ceiling"
        )
        try expect(
            body["max_tokens"] as? Int == 1_024,
            "local Summary sends the legacy 1,024-token completion ceiling"
        )
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
        let result = try await service.generate(
            source: MeetingSummarySource(
                transcript: summaryTranscript,
                calendar: MeetingSummaryCalendarContext(
                    title: "Quarterly Planning",
                    start: start,
                    end: start.addingTimeInterval(1_800),
                    attendees: ["Adaeze Okafor", "linnea@example.com"]
                ),
                languageContext: summaryLanguage
            )
        )
        let models = try recorder.requests().map {
            try string(try requestBody($0)["model"])
        }

        try expect(models == ["primary/model", "fallback/model"], "fallback request order")
        try expect(result.modelID == "fallback/model", "fallback result model")
        // #529: the fallback cloud model doesn't get the calendar either.
        try expectNoCalendar(in: recorder.requests(), title: "Quarterly Planning")
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

    private static func testFallbackTerminalFailureReportsFallbackModel() async throws {
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
            try expect(
                issue.context.modelID == "fallback/model",
                "terminal fallback failure reports the model that returned it"
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

    private static func makeCloudService(
        fallbackModel: String? = nil,
        chunker: MeetingSummaryTextChunker = MeetingSummaryTextChunker(),
        tokenBudgeter: LocalAITokenBudgeter? = nil,
        transport: @escaping MeetingSummaryService.Transport
    ) -> MeetingSummaryService {
        let baseURL = "https://api.example.com/openai/v1/\(UUID().uuidString)"
        return MeetingSummaryService(
            backendExecutor: AIProcessingBackendExecutor(
                choice: .cloud(modelID: "primary/model"),
                cloudBaseURL: baseURL,
                cloudAPIKey: "test-key"
            ),
            cloudFallbackModelID: fallbackModel,
            chunker: chunker,
            tokenBudgeter: tokenBudgeter,
            transport: transport
        )
    }

    /// No part of the calendar event: title, attendees, or the object
    /// that carries its times.
    private static func expectNoCalendar(in requests: [URLRequest], title: String) throws {
        for request in requests {
            let requestText = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            try expect(!requestText.contains(title), "a cloud request leaves the calendar title out")
            try expect(
                !requestText.contains("Adaeze Okafor") && !requestText.contains("linnea@example.com"),
                "a cloud request leaves attendees out"
            )
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

    func requests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storedRequests
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
