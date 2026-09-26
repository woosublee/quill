import Foundation

#if !QUILL_GROUPED_TEST_RUNNER
@main
#endif
struct AppContextBackendTests {
    static func main() async throws {
        try await testLocalContextOmitsScreenshotAndAuthorization()
        try await testLocalVisionContextSendsScreenshotAndRetriesTextOnly()
        try await testCloudContextRetriesWithoutScreenshot()
        try await testCloudThrownTransportRetriesWithoutScreenshot()
        try await testCloudRepeatedTransportFailureRecordsStructuredIssue()
        try await testCloudUnusableResponseRecordsStructuredIssue()
        try await testCloudHTTPStatusPreservesSpecificClassification()
        try await testCloudMissingKeySkipsTransportAndRecordsProviderIssue()
        try testContextFallbackCarriesProviderIssue()
        try testConfiguredContextCollectionPreservesInferenceIssue()
        try testUnconfiguredLocalContextRecordsModelUnavailableIssue()
        try await testCancellationStopsRetryAndDoesNotRecordIssue()
        try await testLocalRequestUsesEndpointRequestAndSelectedModelIDs()
        try testAppStateContextCaptureGuardsCancelledPublication()
        try testAppStatePersistsPostProcessingIssueBeforeContextIssue()
        try testStopTimeFallbackDistinguishesDisabledFromIncompleteCapture()
        try testResolveStoppedRecordingContextSanitizesUnusableCapture()
        try await testLocalFailureReturnsNilAndRecordsPrivateIssue()
        try await testLocalProcessExitRecordsDedicatedIssue()
        print("AppContextBackendTests passed")
    }

    private static let successfulReadinessProbe: LocalAIServerManager.ReadinessProbe = { request in
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (Data("{\"choices\":[{\"message\":{\"content\":\"OK\"}}]}".utf8), response)
    }

    private static func testLocalContextOmitsScreenshotAndAuthorization() async throws {
        let recorder = ContextRequestRecorder()
        let service = AppContextService(
            backendExecutor: localExecutor(manager: readyManager()),
            customContextPrompt: "",
            contextModel: LocalAIModelCatalog.quality.id,
            screenshotMaxDimension: 1024,
            transport: { request in
                recorder.record(request)
                return try successResponse(
                    request,
                    "User is writing a test. They likely want to verify local context."
                )
            }
        )

        let result = await service.inferActivityWithLLM(
            appName: "Editor",
            bundleIdentifier: "test.editor",
            windowTitle: "Document",
            selectedText: "Selected",
            screenshotDataURL: "data:image/jpeg;base64,SECRET_IMAGE",
            contextSystemPrompt: AppContextService.defaultContextPrompt
        )

        try expect(result != nil, "local context result")
        let request = try recorder.request(at: 0)
        try expect(request.url?.host == "127.0.0.1", "local loopback host")
        try expect(request.value(forHTTPHeaderField: "Authorization") == nil, "local authorization")
        let bodyText = try bodyText(for: request)
        try expect(!bodyText.contains("image_url"), "local omits image payload")
        try expect(!bodyText.contains("SECRET_IMAGE"), "local omits screenshot data")
        try expect(bodyText.contains("Selected"), "local includes selected text")
        try expect(recorder.count() == 1, "local sends one text-only request")
    }

    // Gemma 4 E4B reads screenshots on this Mac. If the screenshot request fails
    // (for example a timeout), Context retries with text only, like Cloud does.
    private static func testLocalVisionContextSendsScreenshotAndRetriesTextOnly() async throws {
        let recorder = ContextRequestRecorder()
        let service = AppContextService(
            backendExecutor: localExecutor(
                manager: readyManager(),
                model: LocalAIModelCatalog.gemma4E4B
            ),
            customContextPrompt: "",
            contextModel: LocalAIModelCatalog.gemma4E4B.id,
            screenshotMaxDimension: 1024,
            transport: { request in
                recorder.record(request)
                if recorder.count() == 1 {
                    throw URLError(.timedOut)
                }
                return try successResponse(
                    request,
                    "User is reviewing a checklist. They likely want to confirm release steps."
                )
            }
        )

        let result = await service.inferActivityWithLLM(
            appName: "Notes",
            bundleIdentifier: "test.notes",
            windowTitle: "Checklist",
            selectedText: nil,
            screenshotDataURL: "data:image/jpeg;base64,SYNTHETIC_IMAGE",
            contextSystemPrompt: AppContextService.defaultContextPrompt
        )

        try expect(result != nil, "local vision context recovers with text only")
        try expect(recorder.count() == 2, "local vision context retries once")
        let firstRequest = try recorder.request(at: 0)
        try expect(firstRequest.url?.host == "127.0.0.1", "screenshot goes to the local server only")
        let firstBody = try bodyText(for: firstRequest)
        let retryBody = try bodyText(for: recorder.request(at: 1))
        try expect(firstBody.contains("SYNTHETIC_IMAGE"), "first request carries the screenshot")
        try expect(!retryBody.contains("image_url"), "retry omits the screenshot")
    }

    private static func testCloudContextRetriesWithoutScreenshot() async throws {
        let recorder = ContextRequestRecorder()
        let service = AppContextService(
            apiKey: "cloud-key",
            baseURL: "https://api.example.com/openai/v1",
            customContextPrompt: "",
            contextModel: "qwen/qwen3.6-27b",
            transport: { request in
                recorder.record(request)
                if recorder.count() == 1 {
                    return (
                        Data(),
                        HTTPURLResponse(
                            url: request.url!,
                            statusCode: 500,
                            httpVersion: nil,
                            headerFields: nil
                        )!
                    )
                }
                return try successResponse(
                    request,
                    "User is editing a document. They likely want writing help."
                )
            }
        )

        let result = await service.inferActivityWithLLM(
            appName: "Editor",
            bundleIdentifier: "test.editor",
            windowTitle: "Document",
            selectedText: nil,
            screenshotDataURL: "data:image/jpeg;base64,IMAGE",
            contextSystemPrompt: AppContextService.defaultContextPrompt
        )

        try expect(result != nil, "cloud context result")
        try expect(recorder.count() == 2, "cloud retries once without screenshot")
        let firstBody = try bodyText(for: recorder.request(at: 0))
        let secondBody = try bodyText(for: recorder.request(at: 1))
        try expect(firstBody.contains("image_url"), "cloud first request includes image")
        try expect(!secondBody.contains("image_url"), "cloud retry omits image")
    }

    private static func testCloudThrownTransportRetriesWithoutScreenshot() async throws {
        let recorder = ContextRequestRecorder()
        let service = AppContextService(
            apiKey: "cloud-key",
            baseURL: "https://api.example.com/openai/v1",
            customContextPrompt: "",
            contextModel: "qwen/qwen3.6-27b",
            transport: { request in
                recorder.record(request)
                if recorder.count() == 1 {
                    throw URLError(.cannotConnectToHost)
                }
                return try successResponse(
                    request,
                    "User is editing a document. They likely want writing help."
                )
            }
        )

        let result = await service.inferActivityWithLLM(
            appName: "Editor",
            bundleIdentifier: "test.editor",
            windowTitle: "Document",
            selectedText: nil,
            screenshotDataURL: "data:image/jpeg;base64,IMAGE",
            contextSystemPrompt: AppContextService.defaultContextPrompt
        )

        try expect(result != nil, "cloud thrown transport retry result")
        try expect(recorder.count() == 2, "cloud thrown transport retries once")
        let firstBody = try bodyText(for: recorder.request(at: 0))
        let secondBody = try bodyText(for: recorder.request(at: 1))
        try expect(firstBody.contains("image_url"), "cloud thrown first request includes image")
        try expect(!secondBody.contains("image_url"), "cloud thrown retry omits image")
    }

    private static func testCloudRepeatedTransportFailureRecordsStructuredIssue() async throws {
        let recorder = ContextRequestRecorder()
        let issues = ContextIssueRecorder()
        let service = AppContextService(
            backendExecutor: AIProcessingBackendExecutor(
                choice: .cloud(modelID: "qwen/qwen3.6-27b"),
                cloudBaseURL: "https://api.example.com/openai/v1",
                cloudAPIKey: "cloud-key"
            ),
            customContextPrompt: "",
            contextModel: "qwen/qwen3.6-27b",
            transport: { request in
                recorder.record(request)
                throw URLError(.cannotConnectToHost)
            },
            issueSink: { issue in issues.record(issue) }
        )

        let result = await service.inferActivityWithLLM(
            appName: "Editor",
            bundleIdentifier: "test.editor",
            windowTitle: "Document",
            selectedText: nil,
            screenshotDataURL: "data:image/jpeg;base64,IMAGE",
            contextSystemPrompt: AppContextService.defaultContextPrompt
        )

        try expect(result == nil, "failed cloud context returns fallback signal")
        try expect(recorder.count() == 2, "failed cloud context exhausts text retry")
        try expect(
            issues.last()?.record.code == .networkUnavailable,
            "failed cloud context records structured transport issue"
        )
    }

    // A cloud response that returns HTTP 200 with unusable content (no
    // network/transport error) must still be classified as a Context failure
    // instead of silently falling through with no issue at all — otherwise
    // the fallback metadata summary would look like real captured context.
    private static func testCloudUnusableResponseRecordsStructuredIssue() async throws {
        let recorder = ContextRequestRecorder()
        let issues = ContextIssueRecorder()
        let service = AppContextService(
            backendExecutor: AIProcessingBackendExecutor(
                choice: .cloud(modelID: "qwen/qwen3.6-27b"),
                cloudBaseURL: "https://api.example.com/openai/v1",
                cloudAPIKey: "cloud-key"
            ),
            customContextPrompt: "",
            contextModel: "qwen/qwen3.6-27b",
            transport: { request in
                recorder.record(request)
                return try successResponse(request, "")
            },
            issueSink: { issue in issues.record(issue) }
        )

        let result = await service.inferActivityWithLLM(
            appName: "Editor",
            bundleIdentifier: "test.editor",
            windowTitle: "Document",
            selectedText: nil,
            screenshotDataURL: "data:image/jpeg;base64,IMAGE",
            contextSystemPrompt: AppContextService.defaultContextPrompt
        )

        try expect(result == nil, "unusable cloud content returns fallback signal")
        try expect(recorder.count() == 2, "unusable cloud content exhausts text retry")
        try expect(
            issues.last()?.record.code == .invalidProviderResponse,
            "unusable cloud content is reported as an unusable response, not a down provider"
        )
    }

    // A non-200 HTTP response carries a specific, actionable classification
    // (auth failure, rate limit, provider outage). It must not collapse into
    // the generic "unusable response" bucket used for a 200 with bad content,
    // or the user loses the correct recovery guidance.
    private static func testCloudHTTPStatusPreservesSpecificClassification() async throws {
        let recorder = ContextRequestRecorder()
        let issues = ContextIssueRecorder()
        let service = AppContextService(
            backendExecutor: AIProcessingBackendExecutor(
                choice: .cloud(modelID: "qwen/qwen3.6-27b"),
                cloudBaseURL: "https://api.example.com/openai/v1",
                cloudAPIKey: "cloud-key"
            ),
            customContextPrompt: "",
            contextModel: "qwen/qwen3.6-27b",
            transport: { request in
                recorder.record(request)
                return (
                    Data(),
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 401,
                        httpVersion: nil,
                        headerFields: nil
                    )!
                )
            },
            issueSink: { issue in issues.record(issue) }
        )

        let result = await service.inferActivityWithLLM(
            appName: "Editor",
            bundleIdentifier: "test.editor",
            windowTitle: "Document",
            selectedText: nil,
            screenshotDataURL: "data:image/jpeg;base64,IMAGE",
            contextSystemPrompt: AppContextService.defaultContextPrompt
        )

        try expect(result == nil, "HTTP 401 returns fallback signal")
        try expect(
            issues.last()?.record.code == .authenticationFailed,
            "HTTP 401 keeps its specific classification instead of collapsing into invalidProviderResponse"
        )
    }

    private static func testCloudMissingKeySkipsTransportAndRecordsProviderIssue() async throws {
        let recorder = ContextRequestRecorder()
        let issues = ContextIssueRecorder()
        let service = AppContextService(
            backendExecutor: AIProcessingBackendExecutor(
                choice: .cloud(modelID: "qwen/qwen3.6-27b"),
                cloudBaseURL: "https://api.example.com/openai/v1",
                cloudAPIKey: "  "
            ),
            customContextPrompt: "",
            contextModel: "qwen/qwen3.6-27b",
            transport: { request in
                recorder.record(request)
                return try successResponse(
                    request,
                    "This response must not be requested."
                )
            },
            issueSink: { issue in issues.record(issue) }
        )

        let result = await service.inferActivityWithLLM(
            appName: "Editor",
            bundleIdentifier: "test.editor",
            windowTitle: "Document",
            selectedText: nil,
            screenshotDataURL: nil,
            contextSystemPrompt: AppContextService.defaultContextPrompt
        )

        try expect(result == nil, "keyless cloud context uses metadata fallback")
        try expect(recorder.count() == 0, "keyless cloud context skips transport")
        try expect(
            issues.last()?.record.code == .providerConfigurationInvalid,
            "keyless cloud context records provider configuration issue"
        )
        try expect(
            issues.last()?.record.recoveryAction == .openProviderSettings,
            "keyless cloud context opens Provider settings"
        )
    }

    private static func testContextFallbackCarriesProviderIssue() throws {
        let issue = QuillUserIssueRecord(code: .providerConfigurationInvalid)
        let context = AppContext(
            appName: "Editor",
            bundleIdentifier: "test.editor",
            windowTitle: "Document",
            selectedText: nil,
            currentActivity: "Fallback metadata summary",
            contextSystemPrompt: nil,
            contextPrompt: nil,
            screenshotDataURL: nil,
            screenshotMimeType: nil,
            screenshotError: nil,
            userIssueRecord: issue
        )

        try expect(
            context.contextSummary == "Fallback metadata summary",
            "context issue does not replace fallback summary"
        )
        try expect(
            context.userIssueRecord == issue,
            "context fallback carries structured issue"
        )
    }

    private static func testConfiguredContextCollectionPreservesInferenceIssue() throws {
        let source = try String(
            contentsOfFile: "Sources/AppContextService.swift",
            encoding: .utf8
        )
        guard let start = source.range(of: "func collectContext() async -> AppContext"),
              let end = source.range(
                of: "func inferActivityWithLLM(",
                range: start.upperBound..<source.endIndex
              ) else {
            throw AppContextBackendTestFailure("Context collection source")
        }
        let collection = String(source[start.lowerBound..<end.lowerBound])

        try expect(
            collection.contains("let inference = await inferActivityWithOutcome("),
            "configured Context collection captures the full inference outcome"
        )
        try expect(
            collection.contains("userIssueRecord = inference.userIssueRecord"),
            "configured Context fallback preserves its structured issue"
        )
        try expect(
            source.contains("let issue = contextUserIssue(for: error)"),
            "Context inference classifies failures once"
        )
        try expect(
            source.contains("userIssueRecord: issue.record"),
            "Context inference returns the classified issue"
        )
    }

    // Local Context inference that never even attempts a request (the
    // selected model or hardware isn't configured) must still attach a typed
    // issue, matching every other Context failure branch, instead of
    // silently reporting the fallback metadata summary as usable.
    private static func testUnconfiguredLocalContextRecordsModelUnavailableIssue() throws {
        let source = try String(
            contentsOfFile: "Sources/AppContextService.swift",
            encoding: .utf8
        )
        guard let start = source.range(of: "if backendExecutor.choice.isLocal {"),
              let end = source.range(
                of: "return AppContext(",
                range: start.upperBound..<source.endIndex
              ) else {
            throw AppContextBackendTestFailure("Context not-configured branch source")
        }
        let body = String(source[start.lowerBound..<end.lowerBound])

        try expect(
            !body.contains("userIssueRecord = nil"),
            "unconfigured local Context capture must record a typed issue, not silently succeed"
        )
        try expect(
            body.contains(".localAIModelUnavailable"),
            "unconfigured local Context capture reports the model-unavailable issue"
        )
    }

    private static func testCancellationStopsRetryAndDoesNotRecordIssue() async throws {
        let recorder = ContextRequestRecorder()
        let issues = ContextIssueRecorder()
        let gate = ContextCancellationGate()
        let service = AppContextService(
            backendExecutor: AIProcessingBackendExecutor(
                choice: .cloud(modelID: "qwen/qwen3.6-27b"),
                cloudBaseURL: "https://api.example.com/openai/v1",
                cloudAPIKey: "cloud-key"
            ),
            customContextPrompt: "",
            contextModel: "qwen/qwen3.6-27b",
            transport: { request in
                recorder.record(request)
                await gate.waitForRelease()
                return try successResponse(
                    request,
                    "User is editing a document. They likely want writing help."
                )
            },
            issueSink: { issue in issues.record(issue) }
        )

        let task = Task {
            await service.inferActivityWithLLM(
                appName: "Editor",
                bundleIdentifier: "test.editor",
                windowTitle: "Document",
                selectedText: nil,
                screenshotDataURL: "data:image/jpeg;base64,IMAGE",
                contextSystemPrompt: AppContextService.defaultContextPrompt
            )
        }
        await gate.waitForRequest()
        task.cancel()
        await gate.release()
        let result = await task.value

        try expect(result == nil, "cancelled context returns nil")
        try expect(recorder.count() == 1, "cancelled context does not retry")
        try expect(issues.count() == 0, "cancelled context does not record issue")
    }

    private static func testLocalRequestUsesEndpointRequestAndSelectedModelIDs() async throws {
        let recorder = ContextRequestRecorder()
        let selectedModelID = LocalAIModelCatalog.quality.id
        let service = AppContextService(
            backendExecutor: AIProcessingBackendExecutor(
                choice: .localAI(modelID: selectedModelID),
                cloudBaseURL: "https://api.example.com/openai/v1",
                cloudAPIKey: "cloud-key",
                localServerManager: readyManager(),
                localAIAvailability: LocalAIProcessingAvailability(
                    isAppleSilicon: true,
                    runnerIsExecutable: true,
                    physicalMemory: 16 * 1024 * 1024 * 1024
                )
            ),
            customContextPrompt: "",
            contextModel: selectedModelID,
            transport: { request in
                recorder.record(request)
                return try successResponse(
                    request,
                    "User is writing a document. They likely want editing help."
                )
            }
        )

        let result = await service.inferActivityWithLLM(
            appName: "Editor",
            bundleIdentifier: "test.editor",
            windowTitle: "Document",
            selectedText: nil,
            screenshotDataURL: "data:image/jpeg;base64,SECRET_IMAGE",
            contextSystemPrompt: AppContextService.defaultContextPrompt
        )

        let request = try recorder.request(at: 0)
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        try expect(result?.prompt.contains("Model: \(selectedModelID)") == true, "selected model stays in prompt identity")
        let bodyText = try bodyText(for: request)
        try expect(body["model"] as? String == "local", "local request model uses endpoint request identity")
        try expect(request.value(forHTTPHeaderField: "Authorization") == nil, "local endpoint has no authorization")
        try expect(!bodyText.contains("image_url"), "local endpoint omits image")
    }

    private static func testAppStateContextCaptureGuardsCancelledPublication() throws {
        let source = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)
        guard let captureStart = source.range(of: "private func startContextCapture()"),
              let captureEnd = source.range(of: "    private func fallbackContextAtStop()") else {
            throw AppContextBackendTestFailure("AppState Context capture source")
        }
        let captureBody = String(source[captureStart.lowerBound..<captureEnd.lowerBound])
        let snapshotRange = try requiredRange(
            "let contextService = contextService",
            in: captureBody
        )
        let taskRange = try requiredRange("contextCaptureTask = Task", in: captureBody)
        let resultRange = try requiredRange(
            "let context = await contextService.collectContext()",
            in: captureBody
        )
        let outerGuardRange = try requiredRange(
            "guard !Task.isCancelled else { return nil }",
            in: captureBody
        )
        let mainActorRange = try requiredRange("await MainActor.run {", in: captureBody)
        let innerGuardRange = try requiredRange(
            "guard !Task.isCancelled else { return }",
            in: captureBody
        )
        let mutationRange = try requiredRange("self.capturedContext = context", in: captureBody)

        try expect(snapshotRange.lowerBound < taskRange.lowerBound, "Context service snapshot precedes task creation")
        try expect(taskRange.lowerBound < resultRange.lowerBound, "Context task uses captured service")
        try expect(resultRange.lowerBound < outerGuardRange.lowerBound, "outer guard follows Context result")
        try expect(outerGuardRange.lowerBound < mainActorRange.lowerBound, "outer guard precedes MainActor publish")
        try expect(mainActorRange.lowerBound < innerGuardRange.lowerBound, "inner guard is inside MainActor publish")
        try expect(innerGuardRange.lowerBound < mutationRange.lowerBound, "inner guard precedes Context mutation")
    }

    private static func testAppStatePersistsPostProcessingIssueBeforeContextIssue() throws {
        let source = try String(
            contentsOfFile: "Sources/AppState.swift",
            encoding: .utf8
        )
        guard let start = source.range(
            of: "private func makeStoppedTranscriptionCompletionSummary("
        ), let end = source.range(
            of: "private func runSuccessfulStoppedTranscriptionCompletionPipeline(",
            range: start.upperBound..<source.endIndex
        ) else {
            throw AppContextBackendTestFailure(
                "AppState stopped transcription completion source"
            )
        }
        let completion = String(source[start.lowerBound..<end.lowerBound])
        let postProcessingIssue = try requiredRange(
            "result.userIssueRecord?.persistedStatus",
            in: completion
        )
        let contextIssue = try requiredRange(
            "context.userIssueRecord?.persistedStatus",
            in: completion
        )
        let normalStatus = try requiredRange(
            "Self.statusMessage(",
            in: completion
        )

        try expect(
            postProcessingIssue.lowerBound < contextIssue.lowerBound,
            "Post-processing issue takes priority over Context issue"
        )
        try expect(
            contextIssue.lowerBound < normalStatus.lowerBound,
            "Context issue takes priority over normal success status"
        )
    }

    private static func testStopTimeFallbackDistinguishesDisabledFromIncompleteCapture() throws {
        let source = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)
        guard let start = source.range(of: "private func fallbackContextAtStop() -> AppContext {"),
              let end = source.range(
                of: "private func resolvedContextSystemPrompt()",
                range: start.upperBound..<source.endIndex
              ) else {
            throw AppContextBackendTestFailure("AppState fallbackContextAtStop source")
        }
        let body = String(source[start.lowerBound..<end.lowerBound])

        // Context capture being turned off is an intentional setting: the
        // stop-time fallback must leave the activity empty (genuine text-only
        // post-processing, no placeholder injected into the prompt) rather than
        // read as a failed refresh attempt.
        try expect(
            body.contains("disableContextCapture")
                && body.contains("? \"\""),
            "fallback leaves currentActivity empty when context capture is disabled"
        )
        try expect(
            body.contains("Could not refresh app context at stop time; using text-only post-processing."),
            "fallback keeps the incomplete-capture wording for the still-enabled case"
        )
    }

    // Context is only injected into post-processing when it was successfully
    // captured. A fallback/placeholder or error-severity capture must not be
    // injected as if it were real activity; instead the note should show a
    // warning (not an error) so post-processing still counts as completed.
    private static func testResolveStoppedRecordingContextSanitizesUnusableCapture() throws {
        let source = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)

        guard let resolveStart = source.range(of: "private func resolveStoppedRecordingContext("),
              let resolveEnd = source.range(
                of: "\n    @MainActor\n    private func bootstrapLastTranscriptForPasteAgain",
                range: resolveStart.upperBound..<source.endIndex
              ) else {
            throw AppContextBackendTestFailure("AppState resolveStoppedRecordingContext source")
        }
        let resolveBody = String(source[resolveStart.lowerBound..<resolveEnd.lowerBound])

        try expect(
            resolveBody.contains("Self.sanitizedCapturedContext("),
            "resolveStoppedRecordingContext sanitizes whatever context it resolves"
        )
        try expect(
            resolveBody.contains("contextCaptureDisabled: disableContextCapture"),
            "sanitization is gated by the current context capture setting"
        )

        guard let placeholderStart = source.range(of: "private static func isPlaceholderContextSummary("),
              let placeholderEnd = source.range(
                of: "\n    private static func isUsableCapturedContext",
                range: placeholderStart.upperBound..<source.endIndex
              ) else {
            throw AppContextBackendTestFailure("AppState isPlaceholderContextSummary source")
        }
        let placeholderBody = String(source[placeholderStart.lowerBound..<placeholderEnd.lowerBound])
        try expect(placeholderBody.contains("trimmed.isEmpty"), "empty activity counts as placeholder")
        try expect(
            placeholderBody.contains(
                "Could not refresh app context at stop time; using text-only post-processing."
            ),
            "the stop-time fallback wording is a known placeholder"
        )

        guard let usableStart = source.range(of: "private static func isUsableCapturedContext("),
              let usableEnd = source.range(
                of: "\n    private static func sanitizedCapturedContext",
                range: usableStart.upperBound..<source.endIndex
              ) else {
            throw AppContextBackendTestFailure("AppState isUsableCapturedContext source")
        }
        let usableBody = String(source[usableStart.lowerBound..<usableEnd.lowerBound])
        try expect(
            usableBody.contains("isPlaceholderContextSummary(context.currentActivity)"),
            "usability requires non-placeholder activity"
        )
        try expect(
            usableBody.contains("context.userIssueRecord == nil"),
            "usability requires no captured issue, regardless of severity"
        )

        guard let sanitizeStart = source.range(of: "private static func sanitizedCapturedContext("),
              let sanitizeEnd = source.range(
                of: "\n    private func fallbackContextAtStop",
                range: sanitizeStart.upperBound..<source.endIndex
              ) else {
            throw AppContextBackendTestFailure("AppState sanitizedCapturedContext source")
        }
        let sanitizeBody = String(source[sanitizeStart.lowerBound..<sanitizeEnd.lowerBound])

        let disabledGuardRange = try requiredRange("guard !contextCaptureDisabled else { return context }", in: sanitizeBody)
        let usableGuardRange = try requiredRange("guard !isUsableCapturedContext(context) else { return context }", in: sanitizeBody)
        try expect(
            disabledGuardRange.lowerBound < usableGuardRange.lowerBound,
            "disabled setting bypasses sanitization before checking usability"
        )
        try expect(sanitizeBody.contains("currentActivity: \"\""), "unusable capture is not injected")
        try expect(
            sanitizeBody.contains(
                "context.userIssueRecord ?? QuillUserIssueRecord(code: .contextUnavailable)"
            ),
            "unusable capture preserves its original issue, falling back to a generic warning only when none was recorded"
        )
    }

    private static func testLocalFailureReturnsNilAndRecordsPrivateIssue() async throws {
        let issues = ContextIssueRecorder()
        let service = AppContextService(
            backendExecutor: localExecutor(manager: readyManager()),
            customContextPrompt: "",
            contextModel: LocalAIModelCatalog.quality.id,
            screenshotMaxDimension: 1024,
            transport: { _ in throw URLError(.cannotConnectToHost) },
            issueSink: { issue in issues.record(issue) }
        )

        let result = await service.inferActivityWithLLM(
            appName: "Editor",
            bundleIdentifier: "test.editor",
            windowTitle: "Document",
            selectedText: nil,
            screenshotDataURL: nil,
            contextSystemPrompt: AppContextService.defaultContextPrompt
        )

        try expect(result == nil, "local failure returns metadata fallback signal")
        try expect(issues.last()?.record.code == .postProcessingFailed, "local failure records private issue")
    }

    private static func testLocalProcessExitRecordsDedicatedIssue() async throws {
        let process = ContextFakeProcess()
        let issues = ContextIssueRecorder()
        let service = AppContextService(
            backendExecutor: localExecutor(manager: readyManager(process: process)),
            customContextPrompt: "",
            contextModel: LocalAIModelCatalog.quality.id,
            screenshotMaxDimension: 1024,
            transport: { _ in
                process.simulateExit()
                throw URLError(.networkConnectionLost)
            },
            issueSink: { issue in issues.record(issue) }
        )

        let result = await service.inferActivityWithLLM(
            appName: "Editor",
            bundleIdentifier: "test.editor",
            windowTitle: "Document",
            selectedText: nil,
            screenshotDataURL: nil,
            contextSystemPrompt: AppContextService.defaultContextPrompt
        )

        try expect(result == nil, "process exit returns metadata fallback signal")
        try expect(issues.last()?.record.code == .localAIProcessExited, "process exit records dedicated issue")
    }

    private static func localExecutor(
        manager: LocalAIServerManager,
        model: LocalAIModel = LocalAIModelCatalog.quality
    ) -> AIProcessingBackendExecutor {
        AIProcessingBackendExecutor(
            choice: .localAI(modelID: model.id),
            cloudBaseURL: AppState.defaultAPIBaseURL,
            cloudAPIKey: "cloud-secret",
            localServerManager: manager,
            localAIAvailability: LocalAIProcessingAvailability(
                isAppleSilicon: true,
                runnerIsExecutable: true,
                physicalMemory: 16 * 1024 * 1024 * 1024
            )
        )
    }

    private static func readyManager(process: ContextFakeProcess = ContextFakeProcess()) -> LocalAIServerManager {
        LocalAIServerManager(
            launchProcess: { _, _, port, _ in (process, port) },
            pollHealth: { _ in true },
            readinessProbe: successfulReadinessProbe,
            validateModel: { _ in .ready }
        )
    }

    private static func successResponse(
        _ request: URLRequest,
        _ content: String
    ) throws -> (Data, URLResponse) {
        let data = try JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["content": content]]]
        ])
        return (
            data,
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }

    private static func bodyText(for request: URLRequest) throws -> String {
        guard let body = request.httpBody,
              let text = String(data: body, encoding: .utf8) else {
            throw AppContextBackendTestFailure("request body")
        }
        return text
    }

    private static func requiredRange(
        _ value: String,
        in source: String
    ) throws -> Range<String.Index> {
        guard let range = source.range(of: value) else {
            throw AppContextBackendTestFailure("missing \(value)")
        }
        return range
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ label: String
    ) throws {
        guard condition() else { throw AppContextBackendTestFailure(label) }
    }
}

private final class ContextRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    func record(_ request: URLRequest) {
        lock.lock()
        requests.append(request)
        lock.unlock()
    }

    func request(at index: Int) throws -> URLRequest {
        lock.lock()
        defer { lock.unlock() }
        guard requests.indices.contains(index) else {
            throw AppContextBackendTestFailure("captured request at index \(index)")
        }
        return requests[index]
    }

    func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.count
    }
}

private final class ContextIssueRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var issues: [QuillUserIssueError] = []

    func record(_ issue: QuillUserIssueError) {
        lock.lock()
        issues.append(issue)
        lock.unlock()
    }

    func last() -> QuillUserIssueError? {
        lock.lock()
        defer { lock.unlock() }
        return issues.last
    }

    func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return issues.count
    }
}

private actor ContextCancellationGate {
    private var requestStarted = false
    private var released = false
    private var requestContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func waitForRequest() async {
        if requestStarted { return }
        await withCheckedContinuation { requestContinuation = $0 }
    }

    func waitForRelease() async {
        requestStarted = true
        requestContinuation?.resume()
        requestContinuation = nil
        if released { return }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func release() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private final class ContextFakeProcess: LocalAIServerProcess, @unchecked Sendable {
    private let lock = NSLock()
    private var running = true

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    func terminate() { simulateExit() }
    func forceTerminate() { simulateExit() }
    func setTerminationHandler(_ handler: @escaping () -> Void) {}

    func simulateExit() {
        lock.lock()
        running = false
        lock.unlock()
    }
}

private struct AppContextBackendTestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
