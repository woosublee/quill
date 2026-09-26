import Foundation

#if !QUILL_GROUPED_TEST_RUNNER
@main
#endif
struct TranscriptionRetryWorkflowTests {
    static func main() async throws {
        try await testInitialStateIsInstanceOwned()
        try testHistoryReplacementPreservesUnrelatedMetadata()
        try await testWorkflowInstancesUseIndependentTranscriberDependencies()
        try await testManualRequestCapturesExecutionProcessingAndCloudDependencies()
        try await testManualRejectsInMemoryHistoryBeforeStateMutation()
        try await testLocalAIManualRetryGetsJobStoreContext()
        try await testLocalAIStartupResumeUsesLocalExecution()
        try await testLocalAIRecordWaitsWhenLocalModelChanged()
        try await testManualSuccessPersistsBeforeEffectsAndDelivery()
        try await testManualFallbackUsesFallbackOutcome()
        try await testCommandFallbackUsesCapturedDispositionAndReason()
        try await testProgressBelongsToCurrentAttempt()
        try await testManualProviderFailurePersistsVersionedIssue()
        try await testManualFailureUsesCapturedIssueContext()
        try await testManualFailurePreservesCurrentTranscriptAIAndSummary()
        try await testManualFailurePreservesSummaryActionCompletion()
        try await testTimeoutFallbackPersistsRawTranscriptAndFailedOutcome()
        try testFailureDiagnosticsExcludeCredentialValues()
        try await testTranscriptAssetFailureRemainsBestEffortSuccess()
        try await testHistorySaveFailureDeletesCreatedTranscriptAndSuppressesEffects()
        try await testHistoryLookupFailureMapsToPersistenceFailure()
        try await testMissingHistoryMapsToStale()
        try await testCompatibleCloudRetryReusesStoredRecord()
        try await testIncompatibleProviderRetryRestartsAtFirstChunk()
        try await testIncompatibleModelRetryRestartsAtFirstChunk()
        try await testIncompatibleLanguageRetryRestartsAtFirstChunk()
        try await testIncompatibleResponseFormatRetryRestartsAtFirstChunk()
        try await testIncompatibleUploadCeilingRetryRestartsAtFirstChunk()
        try await testIncompatibleCompletionPolicyRetryRestartsAtFirstChunk()
        try await testLocalRetryDoesNotConsumeCloudCompletedPrefix()
        try await testLocalFailurePreservesExistingCloudSidecar()
        try await testLocalSuccessDeletesSidecarAfterHistoryPersistence()
        try await testHistoryFailurePreservesAssembledSidecar()
        try await testSidecarDeletionFailurePreservesDurableSuccess()
        try await testInvalidateRejectsLateSuccess()
        try await testCancelRejectsLateFailureAndClearsState()
        try await testCancellationDuringPostProcessingEmitsOneTerminalOutcome()
        try await testForgetRemovesNoteState()
        try await testForgetAllRejectsEveryLateCompletion()
        try await testNewerAttemptRejectsOlderSuccessAndProgress()
        try await testNewerAttemptRejectsOlderFailure()
        try await testChangedAudioIdentityRejectsCompletion()
        try await testChangedTimestampRejectsCompletion()
        try await testStaleAttemptDeletesOnlyItsCreatedTranscript()
        try testStartupFilterResumesOnlyExactCompatibleRecords()
        try testStartupFilterPreservesKeylessAndIncompatibleRecordsForRetry()
        try await testStartupResumeUsesPersistedCompletionPolicy()
        try await testStartupResumeUsesStoredContextAndHistoryOnlyDelivery()
        try await testStartupDuplicateHistoryIDsUseFirstItem()
        try await testStartupSuccessPersistsAndDeletesSidecar()
        try await testStartupFallbackPersistsWithoutSummaryInvalidation()
        try await testStartupProviderFailurePreservesPlaceholderAndSidecar()
        try await testStartupCancellationPreservesPlaceholderAndSidecar()
        try await testStartupMissingHistoryDoesNotStartProvider()
        try await testStartupSeedsAndClearsStoredProgress()
        print("TranscriptionRetryWorkflowTests passed")
    }

    @MainActor
    private static func testInitialStateIsInstanceOwned() async throws {
        let first = TranscriptionRetryWorkflow(
            dependencies: unusedDependencies(token: UUID())
        )
        let second = TranscriptionRetryWorkflow(
            dependencies: unusedDependencies(token: UUID())
        )

        try expectEqual(first.state, .initial, "first initial state")
        try expectEqual(second.state, .initial, "second initial state")
        try expect(first.state.retryingNoteIDs.isEmpty, "first retry state")
        try expect(second.state.progressByNoteID.isEmpty, "second progress state")
    }

    private static func testHistoryReplacementPreservesUnrelatedMetadata() throws {
        let summary = MeetingSummaryEnvelope(
            schemaVersion: MeetingSummaryEnvelope.currentSchemaVersion,
            promptVersion: 1,
            generatedAt: Date(timeIntervalSince1970: 3_000),
            sourceFingerprint: String(repeating: "a", count: 64),
            modelID: "summary/model",
            backendKind: .cloud,
            content: MeetingSummaryContent(
                overview: MeetingSummaryEvidenceText(
                    text: "Existing overview",
                    sourceQuotes: []
                ),
                keyPoints: [],
                decisions: [],
                actionItems: [],
                openQuestions: []
            )
        )
        let attempt = MeetingSummaryAttempt(
            occurredAt: Date(timeIntervalSince1970: 3_100),
            outcome: .failed,
            backendKind: .cloud,
            modelID: "summary/model",
            providerHost: "provider.example",
            language: nil,
            issue: QuillUserIssueRecord(code: .meetingSummaryUnavailable)
        )
        let initial = PipelineHistoryItem(
            intent: .dictation,
            selectedText: "selected",
            capturedSelection: "captured",
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_000),
            recordingStartedAt: Date(timeIntervalSince1970: 900),
            recordingEndedAt: Date(timeIntervalSince1970: 990),
            calendarMatch: nil,
            rawTranscript: "old raw",
            postProcessedTranscript: "old final",
            postProcessingPrompt: "old prompt",
            systemPrompt: "system",
            contextSummary: "context",
            contextSystemPrompt: "context system",
            contextPrompt: "context prompt",
            contextScreenshotDataURL: "data:image/jpeg;base64,AA==",
            contextScreenshotStatus: "captured",
            postProcessingStatus: "old status",
            aiProcessingOutcome: "failed:old",
            debugStatus: "old debug",
            customVocabulary: "old vocabulary",
            customSystemPrompt: "old custom prompt",
            audioFileName: "recording.wav",
            usedLocalTranscription: false,
            usedContextCapture: true,
            usedPostProcessing: true,
            transcriptionLanguageCode: "en",
            spokenLanguageCode: "en",
            spokenLanguageResolution: .engineDetected,
            meetingSummaryAttempt: attempt,
            localTranscriptionModelID: "old/local",
            transcriptFileName: "old.txt",
            contextAppName: "Editor",
            contextBundleIdentifier: "com.example.editor",
            contextWindowTitle: "Document",
            customTitle: "Custom title",
            meetingSummaryJSON: try JSONEncoder().encode(summary)
        )
        let replacement = PipelineHistoryTranscriptionReplacement(
            rawTranscript: "new raw",
            postProcessedTranscript: "new final",
            postProcessingPrompt: "new prompt",
            postProcessingStatus: "new status",
            aiProcessingOutcome: AIProcessingOutcome.succeeded.pipelineHistoryStatus,
            debugStatus: "Retried",
            customVocabulary: "new vocabulary",
            customSystemPrompt: "new custom prompt",
            usedLocalTranscription: true,
            usedPostProcessing: false,
            transcriptionLanguageCode: "ko",
            spokenLanguage: SpokenLanguageResolution(
                languageCode: "ko",
                source: .engineDetected
            ),
            localTranscriptionModelID: "new/local",
            transcriptFileName: "new.txt"
        )

        let updated = initial.replacingTranscription(with: replacement)

        try expectEqual(updated.rawTranscript, "new raw", "raw transcript")
        try expectEqual(updated.postProcessedTranscript, "new final", "final transcript")
        try expectEqual(updated.customTitle, "Custom title", "custom title")
        try expectEqual(updated.meetingSummary, summary, "meeting summary")
        try expectEqual(updated.meetingSummaryAttempt, attempt, "summary attempt")
        try expectEqual(updated.capturedSelection, "captured", "selection")
        try expectEqual(updated.contextAppName, "Editor", "context app")
        try expectEqual(updated.audioFileName, "recording.wav", "audio identity")
    }

    @MainActor
    private static func testWorkflowInstancesUseIndependentTranscriberDependencies()
        async throws {
        let firstFixture = try makeFixture()
        let secondFixture = try makeFixture()
        defer {
            firstFixture.cleanup()
            secondFixture.cleanup()
        }
        let firstItem = makeHistoryItem()
        let secondItem = makeHistoryItem()
        let firstHistory = TranscriptionRetryHistoryRecorder(item: firstItem)
        let secondHistory = TranscriptionRetryHistoryRecorder(item: secondItem)
        let firstEvents = TranscriptionRetryEventRecorder()
        let secondEvents = TranscriptionRetryEventRecorder()
        let firstWorkflow = TranscriptionRetryWorkflow(
            dependencies: immediateDependencies(text: "first dependency")
        )
        let secondWorkflow = TranscriptionRetryWorkflow(
            dependencies: immediateDependencies(text: "second dependency")
        )
        firstWorkflow.onEvent = firstEvents.record
        secondWorkflow.onEvent = secondEvents.record

        _ = firstWorkflow.startManual(
            request: try makeRequest(
                item: firstItem,
                fixture: firstFixture,
                processing: processingBehaviorFromTranscription()
            ),
            runtime: firstFixture.runtime(
                history: firstHistory.access(),
                assets: TranscriptionRetryAssetRecorder().access()
            )
        )
        _ = secondWorkflow.startManual(
            request: try makeRequest(
                item: secondItem,
                fixture: secondFixture,
                processing: processingBehaviorFromTranscription()
            ),
            runtime: secondFixture.runtime(
                history: secondHistory.access(),
                assets: TranscriptionRetryAssetRecorder().access()
            )
        )

        try await waitUntil {
            firstEvents.outcomes.count == 1 && secondEvents.outcomes.count == 1
        }
        try expectEqual(
            firstHistory.persistedItems.last?.rawTranscript,
            "first dependency",
            "first workflow dependency"
        )
        try expectEqual(
            secondHistory.persistedItems.last?.rawTranscript,
            "second dependency",
            "second workflow dependency"
        )
    }

    @MainActor
    private static func testManualRequestCapturesExecutionProcessingAndCloudDependencies()
        async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let item = makeHistoryItem()
        let history = TranscriptionRetryHistoryRecorder(item: item)
        let events = TranscriptionRetryEventRecorder()
        let invocation = TranscriptionRetryInvocationRecorder()
        let dependencyRoot = fixture.root.appendingPathComponent(
            "captured-dependencies",
            isDirectory: true
        )
        var externalFinal = "captured final"
        let capturedFinal = externalFinal
        let execution = try makeCloudExecution(
            model: "captured-model",
            completion: TranscriptionCompletionSnapshot(
                postProcessingEnabled: false,
                outputLanguage: "ko",
                pressEnterCommandEnabled: true
            )
        )
        let cloudDependencies = makeCloudDependencies(
            temporaryRoot: dependencyRoot
        )
        let workflow = TranscriptionRetryWorkflow(
            dependencies: TranscriptionRetryWorkflowDependencies(
                transcribe: { execution, _, dependencies, _ in
                    await invocation.record(
                        execution: execution,
                        dependencies: dependencies
                    )
                    return TranscriptionResult(
                        text: "captured raw",
                        spokenLanguage: SpokenLanguageResolution(
                            languageCode: "ko",
                            source: .engineDetected
                        )
                    )
                },
                makeAttemptToken: { UUID() }
            )
        )
        workflow.onEvent = events.record
        let request = try makeRequest(
            item: item,
            fixture: fixture,
            execution: execution,
            cloudDependencies: cloudDependencies,
            processing: TranscriptionRetryProcessingBehavior { transcription in
                processingResult(
                    raw: transcription.text,
                    final: capturedFinal,
                    spokenLanguage: transcription.spokenLanguage
                )
            }
        )
        externalFinal = "mutated final"

        _ = workflow.startManual(
            request: request,
            runtime: fixture.runtime(
                history: history.access(),
                assets: TranscriptionRetryAssetRecorder().access()
            )
        )

        try await waitUntil { events.outcomes.count == 1 }
        let recorded = await invocation.snapshot()
        try expectEqual(recorded?.model, "captured-model", "captured model")
        try expectEqual(recorded?.outputLanguage, "ko", "captured output language")
        try expectEqual(recorded?.pressEnterCommandEnabled, true, "captured command policy")
        try expectEqual(recorded?.temporaryRoot, dependencyRoot, "captured dependencies")
        try expectEqual(
            history.persistedItems.last?.postProcessedTranscript,
            "captured final",
            "captured processing behavior"
        )
        try expectEqual(externalFinal, "mutated final", "external fixture mutation")
    }

    @MainActor
    private static func testManualRejectsInMemoryHistoryBeforeStateMutation()
        async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let item = makeHistoryItem()
        let history = TranscriptionRetryHistoryRecorder(item: item)
        history.durability = .inMemory
        let assets = TranscriptionRetryAssetRecorder()
        let events = TranscriptionRetryEventRecorder()
        let invocation = TranscriptionRetryInvocationRecorder()
        let workflow = TranscriptionRetryWorkflow(
            dependencies: TranscriptionRetryWorkflowDependencies(
                transcribe: { execution, _, dependencies, _ in
                    await invocation.record(
                        execution: execution,
                        dependencies: dependencies
                    )
                    return transcriptionResult(text: "must not run")
                },
                makeAttemptToken: { UUID() }
            )
        )
        workflow.onEvent = events.record

        let started = workflow.startManual(
            request: try makeRequest(item: item, fixture: fixture),
            runtime: fixture.runtime(
                history: history.access(),
                assets: assets.access()
            )
        )

        try expect(!started, "in-memory history start rejected")
        try expectEqual(workflow.state, .initial, "in-memory history state")
        try expect(history.operations.isEmpty, "in-memory history untouched")
        try expect(assets.saved().isEmpty, "in-memory assets untouched")
        try expectEqual(await invocation.count(), 0, "provider did not start")
        try expectEqual(
            events.outcomes,
            [
                .persistenceFailed(
                    QuillUserIssueRecord(code: .historyPersistenceUnavailable)
                )
            ],
            "in-memory completion"
        )
    }

    @MainActor
    private static func testManualSuccessPersistsBeforeEffectsAndDelivery()
        async throws {
        let operationLog = TranscriptionRetryOperationLog()
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let item = makeHistoryItem()
        let history = TranscriptionRetryHistoryRecorder(
            item: item,
            operationLog: operationLog
        )
        let assets = TranscriptionRetryAssetRecorder(operationLog: operationLog)
        let events = TranscriptionRetryEventRecorder(operationLog: operationLog)
        let workflow = TranscriptionRetryWorkflow(
            dependencies: immediateDependencies(text: "provider raw")
        )
        workflow.onEvent = events.record

        let started = workflow.startManual(
            request: try makeRequest(
                item: item,
                fixture: fixture,
                processing: fixedProcessingBehavior(
                    processingResult(raw: "new raw", final: "new final")
                )
            ),
            runtime: fixture.runtime(
                history: history.access(),
                assets: assets.access()
            )
        )

        try expect(started, "manual workflow started")
        try await waitUntil { events.outcomes.count == 1 }
        let saved = try require(history.persistedItems.last, "persisted success item")
        let persistedEvent = try require(events.persistedEvents.last, "persisted success event")
        let completion = try requireSuccessCompletion(events.outcomes.last)

        try expectEqual(saved.rawTranscript, "new raw", "saved raw")
        try expectEqual(saved.postProcessedTranscript, "new final", "saved final")
        try expectEqual(saved.customTitle, "Current title", "current metadata base")
        try expectEqual(
            persistedEvent.effects,
            TranscriptionRetryPersistedEffects(
                advancesWarningGeneration: true,
                invalidatesMeetingSummary: true
            ),
            "manual persisted effects"
        )
        try expectEqual(completion.interactiveTranscript, "new final", "interactive delivery")
        try expect(completion.transcriptAssetPersisted, "transcript asset saved")
        try expectEqual(
            operationLog.values(),
            [
                "state:started",
                "history:lookup",
                "asset:save",
                "history:persist",
                "event:itemPersisted",
                "state:finished",
                "event:completed"
            ],
            "manual success event order"
        )
    }

    @MainActor
    private static func testManualFallbackUsesFallbackOutcome() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let item = makeHistoryItem()
        let history = TranscriptionRetryHistoryRecorder(item: item)
        let events = TranscriptionRetryEventRecorder()
        let workflow = TranscriptionRetryWorkflow(
            dependencies: immediateDependencies(text: "provider raw")
        )
        workflow.onEvent = events.record

        _ = workflow.startManual(
            request: try makeRequest(
                item: item,
                fixture: fixture,
                processing: fixedProcessingBehavior(
                    processingResult(
                        raw: "raw fallback",
                        final: "raw fallback",
                        disposition: .fallback,
                        outcome: .failed(reason: "request-timed-out")
                    )
                )
            ),
            runtime: fixture.runtime(
                history: history.access(),
                assets: TranscriptionRetryAssetRecorder().access()
            )
        )

        try await waitUntil { events.outcomes.count == 1 }
        let saved = try require(history.persistedItems.last, "persisted fallback item")
        guard case .fallback(let completion)? = events.outcomes.last else {
            throw TranscriptionRetryWorkflowTestFailure("fallback outcome")
        }
        try expectEqual(saved.rawTranscript, "raw fallback", "fallback raw")
        try expectEqual(saved.postProcessedTranscript, "raw fallback", "fallback final")
        try expectEqual(
            saved.aiProcessingOutcome,
            "failed:request-timed-out",
            "fallback AI outcome"
        )
        try expectEqual(completion.interactiveTranscript, "raw fallback", "fallback delivery")
        try expectEqual(
            events.persistedEvents.last?.effects,
            TranscriptionRetryPersistedEffects(
                advancesWarningGeneration: true,
                invalidatesMeetingSummary: true
            ),
            "fallback effects"
        )
    }

    @MainActor
    private static func testCommandFallbackUsesCapturedDispositionAndReason()
        async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let item = makeHistoryItem()
        let history = TranscriptionRetryHistoryRecorder(item: item)
        let events = TranscriptionRetryEventRecorder()
        let workflow = TranscriptionRetryWorkflow(
            dependencies: immediateDependencies(text: "new paragraph command")
        )
        workflow.onEvent = events.record

        _ = workflow.startManual(
            request: try makeRequest(
                item: item,
                fixture: fixture,
                processing: fixedProcessingBehavior(
                    TranscriptionRetryProcessingResult(
                        rawTranscript: "new paragraph command",
                        finalTranscript: "new paragraph command",
                        prompt: "command prompt",
                        postProcessingStatus: "Command fallback",
                        aiProcessingOutcome: .failed(reason: "command-transform-failed"),
                        spokenLanguage: SpokenLanguageResolution(
                            languageCode: "en",
                            source: .engineDetected
                        ),
                        disposition: .fallback
                    )
                )
            ),
            runtime: fixture.runtime(
                history: history.access(),
                assets: TranscriptionRetryAssetRecorder().access()
            )
        )

        try await waitUntil { events.outcomes.count == 1 }
        let saved = try require(history.persistedItems.last, "persisted command fallback")
        guard case .fallback? = events.outcomes.last else {
            throw TranscriptionRetryWorkflowTestFailure("command fallback outcome")
        }
        try expectEqual(saved.postProcessingStatus, "Command fallback", "command status")
        try expectEqual(
            saved.aiProcessingOutcome,
            "failed:command-transform-failed",
            "command fallback reason"
        )
    }

    @MainActor
    private static func testProgressBelongsToCurrentAttempt() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let item = makeHistoryItem()
        let history = TranscriptionRetryHistoryRecorder(item: item)
        let events = TranscriptionRetryEventRecorder()
        let gate = TranscriptionRetryControlledTranscriber()
        let workflow = TranscriptionRetryWorkflow(
            dependencies: TranscriptionRetryWorkflowDependencies(
                transcribe: { _, _, _, context in
                    try await gate.run(context: context)
                },
                makeAttemptToken: { UUID() }
            )
        )
        workflow.onEvent = events.record

        _ = workflow.startManual(
            request: try makeRequest(item: item, fixture: fixture),
            runtime: fixture.runtime(
                history: history.access(),
                assets: TranscriptionRetryAssetRecorder().access()
            )
        )

        await gate.waitUntilStarted()
        try await waitUntil {
            workflow.state.progressByNoteID[item.id] != nil
        }
        try expectEqual(
            workflow.state.progressByNoteID[item.id],
            CloudTranscriptionDisplayProgress(
                completedChunkCount: 1,
                totalChunkCount: 3,
                activeAttempt: 2
            ),
            "active attempt progress"
        )
        await gate.succeed(transcriptionResult(text: "provider raw"))
        try await waitUntil { events.outcomes.count == 1 }
        try expect(workflow.state.progressByNoteID[item.id] == nil, "progress cleared")
        try expect(!workflow.state.retryingNoteIDs.contains(item.id), "retry state cleared")
    }

    @MainActor
    private static func testManualProviderFailurePersistsVersionedIssue()
        async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let item = makeHistoryItem()
        let history = TranscriptionRetryHistoryRecorder(item: item)
        let events = TranscriptionRetryEventRecorder()
        let expectedIssue = QuillUserIssueError(
            record: QuillUserIssueRecord(code: .providerUnavailable),
            privateDiagnostic: "safe provider diagnostic"
        )
        let workflow = TranscriptionRetryWorkflow(
            dependencies: failingDependencies(expectedIssue)
        )
        workflow.onEvent = events.record

        _ = workflow.startManual(
            request: try makeRequest(item: item, fixture: fixture),
            runtime: fixture.runtime(
                history: history.access(),
                assets: TranscriptionRetryAssetRecorder().access()
            )
        )

        try await waitUntil { events.outcomes.count == 1 }
        let saved = try require(history.persistedItems.last, "persisted provider failure")
        guard case .failed(let failure)? = events.outcomes.last else {
            throw TranscriptionRetryWorkflowTestFailure("provider failure outcome")
        }
        try expectEqual(saved.userIssueRecord?.code, .providerUnavailable, "failure code")
        try expect(saved.postProcessingStatus.hasPrefix("user-issue:v1:"), "versioned issue")
        try expectEqual(failure.issue.code, .providerUnavailable, "typed failure code")
        try expect(failure.historyPersisted, "manual failure persisted")
        try expectEqual(
            events.persistedEvents.last?.effects,
            TranscriptionRetryPersistedEffects(
                advancesWarningGeneration: true,
                invalidatesMeetingSummary: false
            ),
            "manual failure effects"
        )
    }

    @MainActor
    private static func testManualFailureUsesCapturedIssueContext() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let item = makeHistoryItem()
        let history = TranscriptionRetryHistoryRecorder(item: item)
        let events = TranscriptionRetryEventRecorder()
        var providerHost = "captured.example"
        var modelID = "captured-model"
        var localBackend: String?
        let capturedContext = TranscriptionRetryFailureContext(
            fallbackCode: .providerUnavailable,
            providerHost: providerHost,
            modelID: modelID,
            localBackend: localBackend
        )
        let workflow = TranscriptionRetryWorkflow(
            dependencies: failingDependencies(
                TranscriptionRetryInjectedError.provider
            )
        )
        workflow.onEvent = events.record
        let request = try makeRequest(
            item: item,
            fixture: fixture,
            failureContext: capturedContext
        )
        providerHost = "mutated.example"
        modelID = "mutated-model"
        localBackend = "mutated-backend"

        _ = workflow.startManual(
            request: request,
            runtime: fixture.runtime(
                history: history.access(),
                assets: TranscriptionRetryAssetRecorder().access()
            )
        )

        try await waitUntil { events.outcomes.count == 1 }
        let issue = try require(
            history.persistedItems.last?.userIssueRecord,
            "captured issue"
        )
        try expectEqual(issue.context.providerHost, "captured.example", "provider host")
        try expectEqual(issue.context.modelID, "captured-model", "failure model")
        try expect(issue.context.localBackend == nil, "cloud issue has no local backend")
        try expectEqual(providerHost, "mutated.example", "external host mutation")
        try expectEqual(modelID, "mutated-model", "external model mutation")
        try expectEqual(localBackend, "mutated-backend", "external backend mutation")
    }

    @MainActor
    private static func testManualFailurePreservesCurrentTranscriptAIAndSummary()
        async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let summary = makeMeetingSummary(actionCompleted: false)
        let initial = makeHistoryItem(rawTranscript: "starting raw")
            .withMeetingSummary(summary)
        let current = makeHistoryItem(
            id: initial.id,
            timestamp: initial.timestamp,
            rawTranscript: "current raw",
            postProcessedTranscript: "current final",
            aiProcessingOutcome: "failed:current"
        )
        .withMeetingSummary(summary)
        let history = TranscriptionRetryHistoryRecorder(item: current)
        let events = TranscriptionRetryEventRecorder()
        let workflow = TranscriptionRetryWorkflow(
            dependencies: failingDependencies(
                TranscriptionRetryInjectedError.provider
            )
        )
        workflow.onEvent = events.record

        _ = workflow.startManual(
            request: try makeRequest(item: initial, fixture: fixture),
            runtime: fixture.runtime(
                history: history.access(),
                assets: TranscriptionRetryAssetRecorder().access()
            )
        )

        try await waitUntil { events.outcomes.count == 1 }
        let saved = try require(history.persistedItems.last, "preserved failure item")
        try expectEqual(saved.rawTranscript, "current raw", "failure raw")
        try expectEqual(saved.postProcessedTranscript, "current final", "failure final")
        try expectEqual(saved.aiProcessingOutcome, "failed:current", "failure AI outcome")
        try expectEqual(saved.meetingSummary, summary, "failure Summary")
        try expectEqual(saved.customTitle, "Current title", "failure custom title")
        try expectEqual(saved.debugStatus, "Retry failed", "failure debug status")
    }

    @MainActor
    private static func testManualFailurePreservesSummaryActionCompletion()
        async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let summary = makeMeetingSummary(actionCompleted: true)
        let item = makeHistoryItem().withMeetingSummary(summary)
        let originalJSON = try require(item.meetingSummaryJSON, "summary JSON")
        let history = TranscriptionRetryHistoryRecorder(item: item)
        let events = TranscriptionRetryEventRecorder()
        let workflow = TranscriptionRetryWorkflow(
            dependencies: failingDependencies(
                TranscriptionRetryInjectedError.provider
            )
        )
        workflow.onEvent = events.record

        _ = workflow.startManual(
            request: try makeRequest(item: item, fixture: fixture),
            runtime: fixture.runtime(
                history: history.access(),
                assets: TranscriptionRetryAssetRecorder().access()
            )
        )

        try await waitUntil { events.outcomes.count == 1 }
        let saved = try require(history.persistedItems.last, "action completion item")
        try expectEqual(saved.meetingSummaryJSON, originalJSON, "summary JSON bytes")
        try expectEqual(
            saved.meetingSummary?.content.actionItems.first?.isCompleted,
            true,
            "action completion"
        )
    }

    @MainActor
    private static func testTimeoutFallbackPersistsRawTranscriptAndFailedOutcome()
        async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let item = makeHistoryItem()
        let history = TranscriptionRetryHistoryRecorder(item: item)
        let events = TranscriptionRetryEventRecorder()
        let workflow = TranscriptionRetryWorkflow(
            dependencies: immediateDependencies(text: "timeout raw")
        )
        workflow.onEvent = events.record

        _ = workflow.startManual(
            request: try makeRequest(
                item: item,
                fixture: fixture,
                processing: fixedProcessingBehavior(
                    processingResult(
                        raw: "timeout raw",
                        final: "timeout raw",
                        disposition: .fallback,
                        outcome: .failed(reason: "request-timed-out")
                    )
                )
            ),
            runtime: fixture.runtime(
                history: history.access(),
                assets: TranscriptionRetryAssetRecorder().access()
            )
        )

        try await waitUntil { events.outcomes.count == 1 }
        let saved = try require(history.persistedItems.last, "timeout fallback item")
        try expectEqual(saved.rawTranscript, "timeout raw", "timeout raw")
        try expectEqual(saved.postProcessedTranscript, "timeout raw", "timeout final")
        try expectEqual(
            saved.aiProcessingOutcome,
            "failed:request-timed-out",
            "timeout outcome"
        )
    }

    private static func testFailureDiagnosticsExcludeCredentialValues() throws {
        let credential = "quill-secret-sentinel-318"
        let wrapped = NSError(
            domain: "RetryWrapper",
            code: 7,
            userInfo: [
                NSUnderlyingErrorKey: URLError(.timedOut),
                NSLocalizedDescriptionKey: credential
            ]
        )
        let issue = TranscriptionRetryWorkflow.classifyFailure(
            wrapped,
            context: TranscriptionRetryFailureContext(
                fallbackCode: .providerConfigurationInvalid,
                providerHost: "provider.example",
                modelID: "whisper-large-v3",
                localBackend: nil
            )
        )
        let reflectedRecord = String(reflecting: issue.record)

        try expectEqual(issue.record.code, .requestTimedOut, "wrapped URL error")
        try expect(!issue.privateDiagnostic.contains(credential), "diagnostic credential")
        try expect(!reflectedRecord.contains(credential), "record credential")
    }

    @MainActor
    private static func testTranscriptAssetFailureRemainsBestEffortSuccess()
        async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let item = makeHistoryItem()
        let history = TranscriptionRetryHistoryRecorder(item: item)
        let assets = TranscriptionRetryAssetRecorder()
        assets.saveError = TranscriptionRetryInjectedError.assetSave
        let events = TranscriptionRetryEventRecorder()
        let workflow = TranscriptionRetryWorkflow(
            dependencies: immediateDependencies(text: "provider raw")
        )
        workflow.onEvent = events.record

        _ = workflow.startManual(
            request: try makeRequest(item: item, fixture: fixture),
            runtime: fixture.runtime(
                history: history.access(),
                assets: assets.access()
            )
        )

        try await waitUntil { events.outcomes.count == 1 }
        let saved = try require(history.persistedItems.last, "asset failure item")
        let completion = try requireSuccessCompletion(events.outcomes.last)
        try expect(saved.transcriptFileName == nil, "asset filename remains nil")
        try expect(!completion.transcriptAssetPersisted, "asset failure is best effort")
    }

    @MainActor
    private static func testHistorySaveFailureDeletesCreatedTranscriptAndSuppressesEffects()
        async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let item = makeHistoryItem()
        let history = TranscriptionRetryHistoryRecorder(item: item)
        history.persistError = TranscriptionRetryInjectedError.historySave
        let assets = TranscriptionRetryAssetRecorder()
        let events = TranscriptionRetryEventRecorder()
        let workflow = TranscriptionRetryWorkflow(
            dependencies: immediateDependencies(text: "provider raw")
        )
        workflow.onEvent = events.record

        _ = workflow.startManual(
            request: try makeRequest(item: item, fixture: fixture),
            runtime: fixture.runtime(
                history: history.access(),
                assets: assets.access()
            )
        )

        try await waitUntil { events.outcomes.count == 1 }
        try expectEqual(assets.deleted(), ["created.txt"], "created asset cleanup")
        try expect(events.persistedEvents.isEmpty, "no durable item event")
        try expectEqual(
            events.outcomes,
            [
                .persistenceFailed(
                    QuillUserIssueRecord(code: .historyPersistenceUnavailable)
                )
            ],
            "history failure outcome"
        )
    }

    @MainActor
    private static func testHistoryLookupFailureMapsToPersistenceFailure()
        async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let item = makeHistoryItem()
        let history = TranscriptionRetryHistoryRecorder(item: item)
        history.lookupError = TranscriptionRetryInjectedError.historyRead
        let assets = TranscriptionRetryAssetRecorder()
        let events = TranscriptionRetryEventRecorder()
        let workflow = TranscriptionRetryWorkflow(
            dependencies: immediateDependencies(text: "provider raw")
        )
        workflow.onEvent = events.record

        _ = workflow.startManual(
            request: try makeRequest(item: item, fixture: fixture),
            runtime: fixture.runtime(
                history: history.access(),
                assets: assets.access()
            )
        )

        try await waitUntil { events.outcomes.count == 1 }
        try expectEqual(
            events.outcomes,
            [
                .persistenceFailed(
                    QuillUserIssueRecord(code: .historyPersistenceUnavailable)
                )
            ],
            "history lookup outcome"
        )
        try expect(history.persistedItems.isEmpty, "lookup failure not persisted")
        try expect(assets.saved().isEmpty, "lookup failure creates no asset")
    }

    @MainActor
    private static func testMissingHistoryMapsToStale() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let item = makeHistoryItem()
        let history = TranscriptionRetryHistoryRecorder(item: nil)
        let assets = TranscriptionRetryAssetRecorder()
        let events = TranscriptionRetryEventRecorder()
        let workflow = TranscriptionRetryWorkflow(
            dependencies: immediateDependencies(text: "provider raw")
        )
        workflow.onEvent = events.record

        _ = workflow.startManual(
            request: try makeRequest(item: item, fixture: fixture),
            runtime: fixture.runtime(
                history: history.access(),
                assets: assets.access()
            )
        )

        try await waitUntil { events.outcomes.count == 1 }
        try expectEqual(events.outcomes, [.stale], "missing history outcome")
        try expect(history.persistedItems.isEmpty, "missing history not persisted")
        try expect(assets.saved().isEmpty, "missing history creates no asset")
    }

    @MainActor
    private static func testCompatibleCloudRetryReusesStoredRecord()
        async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let item = makeHistoryItem()
        let configuration = defaultCloudConfiguration(fixture: fixture)
        let stored = try makeCloudState(
            historyID: item.id,
            fixture: fixture,
            configuration: configuration,
            completedPrefix: ["stored prefix"]
        )
        try createStoredRecord(stored.record, in: fixture.jobStore)
        let observation = TranscriptionRetryCloudContextRecorder()
        let history = TranscriptionRetryHistoryRecorder(item: item)
        let events = TranscriptionRetryEventRecorder()
        let workflow = TranscriptionRetryWorkflow(
            dependencies: TranscriptionRetryWorkflowDependencies(
                transcribe: { _, _, _, context in
                    guard let context else {
                        throw TranscriptionRetryWorkflowTestFailure(
                            "missing compatible cloud context"
                        )
                    }
                    let checkpoint = try await context.checkpointStore
                        .loadCompatible(identity: stored.record.identity)
                    await observation.record(
                        oldRecordPresentBeforePreparation: true,
                        completedPrefix: checkpoint?.completedRawTranscripts ?? [],
                        preparedRecord: try fixture.jobStore.load(
                            historyID: item.id
                        )
                    )
                    return transcriptionResult(text: "continued cloud result")
                },
                makeAttemptToken: { UUID() }
            )
        )
        workflow.onEvent = events.record

        _ = workflow.startManual(
            request: try makeRequest(
                item: item,
                fixture: fixture,
                execution: stored.execution
            ),
            runtime: fixture.runtime(
                history: history.access(),
                assets: TranscriptionRetryAssetRecorder().access()
            )
        )

        try await waitUntil { events.outcomes.count == 1 }
        let snapshot = try require(
            await observation.snapshot(),
            "compatible checkpoint observation"
        )
        try expectEqual(
            snapshot.completedPrefix,
            ["stored prefix"],
            "compatible completed prefix"
        )
        let compatibleSidecar = try fixture.jobStore.load(historyID: item.id)
        try expect(
            compatibleSidecar == nil,
            "compatible sidecar deleted after durable success"
        )
    }

    @MainActor
    private static func testIncompatibleProviderRetryRestartsAtFirstChunk()
        async throws {
        try await assertIncompatibleRetryRestarts(.provider)
    }

    @MainActor
    private static func testIncompatibleModelRetryRestartsAtFirstChunk()
        async throws {
        try await assertIncompatibleRetryRestarts(.model)
    }

    @MainActor
    private static func testIncompatibleLanguageRetryRestartsAtFirstChunk()
        async throws {
        try await assertIncompatibleRetryRestarts(.language)
    }

    @MainActor
    private static func testIncompatibleResponseFormatRetryRestartsAtFirstChunk()
        async throws {
        try await assertIncompatibleRetryRestarts(.responseFormat)
    }

    @MainActor
    private static func testIncompatibleUploadCeilingRetryRestartsAtFirstChunk()
        async throws {
        try await assertIncompatibleRetryRestarts(.uploadCeiling)
    }

    @MainActor
    private static func testIncompatibleCompletionPolicyRetryRestartsAtFirstChunk()
        async throws {
        try await assertIncompatibleRetryRestarts(.completionPolicy)
    }

    @MainActor
    private static func assertIncompatibleRetryRestarts(
        _ mismatch: TranscriptionRetryCloudMismatch
    ) async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let item = makeHistoryItem()
        let existingConfiguration = defaultCloudConfiguration(fixture: fixture)
        let currentConfiguration = mismatch.applying(
            to: existingConfiguration,
            fixture: fixture
        )
        let existing = try makeCloudState(
            historyID: item.id,
            fixture: fixture,
            configuration: existingConfiguration,
            completedPrefix: ["old prefix"]
        )
        let current = try makeCloudState(
            historyID: item.id,
            fixture: fixture,
            configuration: currentConfiguration
        )
        try createStoredRecord(existing.record, in: fixture.jobStore)
        let observation = TranscriptionRetryCloudContextRecorder()
        let history = TranscriptionRetryHistoryRecorder(item: item)
        let events = TranscriptionRetryEventRecorder()
        let workflow = TranscriptionRetryWorkflow(
            dependencies: TranscriptionRetryWorkflowDependencies(
                transcribe: { _, _, _, context in
                    guard let context else {
                        throw TranscriptionRetryWorkflowTestFailure(
                            "missing incompatible cloud context"
                        )
                    }
                    let oldRecordPresent = try fixture.jobStore.load(
                        historyID: item.id
                    ) != nil
                    guard let preparing = context.checkpointStore
                        as? any CloudTranscriptionCheckpointPreparing else {
                        throw TranscriptionRetryWorkflowTestFailure(
                            "checkpoint store does not prepare"
                        )
                    }
                    try await preparing.prepare(
                        identity: current.record.identity,
                        plan: current.record.plan
                    )
                    let checkpoint = try await context.checkpointStore
                        .loadCompatible(identity: current.record.identity)
                    await observation.record(
                        oldRecordPresentBeforePreparation: oldRecordPresent,
                        completedPrefix: checkpoint?.completedRawTranscripts ?? [],
                        preparedRecord: try fixture.jobStore.load(
                            historyID: item.id
                        )
                    )
                    return transcriptionResult(text: "fresh cloud result")
                },
                makeAttemptToken: { UUID() }
            )
        )
        workflow.onEvent = events.record

        _ = workflow.startManual(
            request: try makeRequest(
                item: item,
                fixture: fixture,
                execution: current.execution
            ),
            runtime: fixture.runtime(
                history: history.access(),
                assets: TranscriptionRetryAssetRecorder().access()
            )
        )

        try await waitUntil { events.outcomes.count == 1 }
        let snapshot = try require(
            await observation.snapshot(),
            "\(mismatch.label) observation"
        )
        try expect(
            !snapshot.oldRecordPresentBeforePreparation,
            "\(mismatch.label) old record removed before provider"
        )
        try expect(snapshot.completedPrefix.isEmpty, "\(mismatch.label) prefix reset")
        try expectEqual(
            snapshot.preparedRecord?.firstIncompleteChunkIndex,
            0,
            "\(mismatch.label) starts at first chunk"
        )
        try expectEqual(
            snapshot.preparedRecord?.completionPolicy,
            currentConfiguration.completionPolicy,
            "\(mismatch.label) current completion policy"
        )
    }

    @MainActor
    private static func testLocalRetryDoesNotConsumeCloudCompletedPrefix()
        async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let item = makeHistoryItem()
        let cloud = try makeCloudState(
            historyID: item.id,
            fixture: fixture,
            configuration: defaultCloudConfiguration(fixture: fixture),
            completedPrefix: ["cloud prefix must be ignored"]
        )
        try createStoredRecord(cloud.record, in: fixture.jobStore)
        let invocation = TranscriptionRetryLocalContextRecorder()
        let history = TranscriptionRetryHistoryRecorder(item: item)
        let events = TranscriptionRetryEventRecorder()
        let workflow = TranscriptionRetryWorkflow(
            dependencies: TranscriptionRetryWorkflowDependencies(
                transcribe: { _, _, _, context in
                    await invocation.record(contextWasNil: context == nil)
                    return transcriptionResult(text: "local only")
                },
                makeAttemptToken: { UUID() }
            )
        )
        workflow.onEvent = events.record

        _ = workflow.startManual(
            request: try makeRequest(
                item: item,
                fixture: fixture,
                execution: makeLocalExecution(),
                processing: processingBehaviorFromTranscription(),
                historyMetadata: localHistoryMetadata(),
                failureContext: localFailureContext()
            ),
            runtime: fixture.runtime(
                history: history.access(),
                assets: TranscriptionRetryAssetRecorder().access()
            )
        )

        try await waitUntil { events.outcomes.count == 1 }
        let localContextWasNil = await invocation.contextWasNil()
        try expect(localContextWasNil, "local retry has no cloud context")
        try expectEqual(
            history.persistedItems.last?.rawTranscript,
            "local only",
            "local result excludes cloud prefix"
        )
        let localSidecar = try fixture.jobStore.load(historyID: item.id)
        try expect(
            localSidecar == nil,
            "local success deletes prior sidecar"
        )
    }

    @MainActor
    private static func testLocalFailurePreservesExistingCloudSidecar()
        async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let item = makeHistoryItem()
        let cloud = try makeCloudState(
            historyID: item.id,
            fixture: fixture,
            configuration: defaultCloudConfiguration(fixture: fixture),
            completedPrefix: ["cloud prefix"]
        )
        try createStoredRecord(cloud.record, in: fixture.jobStore)
        let history = TranscriptionRetryHistoryRecorder(item: item)
        let events = TranscriptionRetryEventRecorder()
        let workflow = TranscriptionRetryWorkflow(
            dependencies: failingDependencies(
                TranscriptionRetryInjectedError.provider
            )
        )
        workflow.onEvent = events.record

        _ = workflow.startManual(
            request: try makeRequest(
                item: item,
                fixture: fixture,
                execution: makeLocalExecution(),
                historyMetadata: localHistoryMetadata(),
                failureContext: localFailureContext()
            ),
            runtime: fixture.runtime(
                history: history.access(),
                assets: TranscriptionRetryAssetRecorder().access()
            )
        )

        try await waitUntil { events.outcomes.count == 1 }
        try expectEqual(
            try fixture.jobStore.load(historyID: item.id),
            cloud.record,
            "local failure preserves cloud sidecar"
        )
    }

    @MainActor
    private static func testLocalSuccessDeletesSidecarAfterHistoryPersistence()
        async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let item = makeHistoryItem()
        let cloud = try makeCloudState(
            historyID: item.id,
            fixture: fixture,
            configuration: defaultCloudConfiguration(fixture: fixture),
            completedPrefix: ["cloud prefix"]
        )
        try createStoredRecord(cloud.record, in: fixture.jobStore)
        let operations = TranscriptionRetryOperationLog()
        let instrumentedStore = makeInstrumentedStore(
            fixture: fixture,
            operationLog: operations
        )
        let history = TranscriptionRetryHistoryRecorder(
            item: item,
            operationLog: operations
        )
        let events = TranscriptionRetryEventRecorder(operationLog: operations)
        let workflow = TranscriptionRetryWorkflow(
            dependencies: immediateDependencies(text: "local result")
        )
        workflow.onEvent = events.record

        _ = workflow.startManual(
            request: try makeRequest(
                item: item,
                fixture: fixture,
                execution: makeLocalExecution(),
                historyMetadata: localHistoryMetadata(),
                failureContext: localFailureContext()
            ),
            runtime: fixture.runtime(
                history: history.access(),
                assets: TranscriptionRetryAssetRecorder().access(),
                jobStore: instrumentedStore
            )
        )

        try await waitUntil { events.outcomes.count == 1 }
        let values = operations.values()
        let historyIndex = try require(
            values.firstIndex(of: "history:persist"),
            "history persistence operation"
        )
        let sidecarIndex = try require(
            values.firstIndex(of: "sidecar:delete"),
            "sidecar deletion operation"
        )
        try expect(historyIndex < sidecarIndex, "history persists before sidecar delete")
        let remainingSidecar = try instrumentedStore.load(historyID: item.id)
        try expect(
            remainingSidecar == nil,
            "local sidecar deleted"
        )
    }

    @MainActor
    private static func testHistoryFailurePreservesAssembledSidecar()
        async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let item = makeHistoryItem()
        let cloud = try makeCloudState(
            historyID: item.id,
            fixture: fixture,
            configuration: defaultCloudConfiguration(fixture: fixture),
            completeAllChunks: true
        )
        try createStoredRecord(cloud.record, in: fixture.jobStore)
        let history = TranscriptionRetryHistoryRecorder(item: item)
        history.persistError = TranscriptionRetryInjectedError.historySave
        let events = TranscriptionRetryEventRecorder()
        let workflow = TranscriptionRetryWorkflow(
            dependencies: immediateDependencies(text: "assembled result")
        )
        workflow.onEvent = events.record

        _ = workflow.startManual(
            request: try makeRequest(
                item: item,
                fixture: fixture,
                execution: cloud.execution
            ),
            runtime: fixture.runtime(
                history: history.access(),
                assets: TranscriptionRetryAssetRecorder().access()
            )
        )

        try await waitUntil { events.outcomes.count == 1 }
        try expectEqual(
            try fixture.jobStore.load(historyID: item.id),
            cloud.record,
            "history failure preserves assembled sidecar"
        )
        try expect(events.persistedEvents.isEmpty, "history failure suppresses item event")
    }

    @MainActor
    private static func testSidecarDeletionFailurePreservesDurableSuccess()
        async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let item = makeHistoryItem()
        let cloud = try makeCloudState(
            historyID: item.id,
            fixture: fixture,
            configuration: defaultCloudConfiguration(fixture: fixture),
            completedPrefix: ["cloud prefix"]
        )
        try createStoredRecord(cloud.record, in: fixture.jobStore)
        let failingStore = makeInstrumentedStore(
            fixture: fixture,
            operationLog: TranscriptionRetryOperationLog(),
            deletionError: .sidecarDelete
        )
        let history = TranscriptionRetryHistoryRecorder(item: item)
        let events = TranscriptionRetryEventRecorder()
        let workflow = TranscriptionRetryWorkflow(
            dependencies: immediateDependencies(text: "durable result")
        )
        workflow.onEvent = events.record

        _ = workflow.startManual(
            request: try makeRequest(
                item: item,
                fixture: fixture,
                execution: cloud.execution
            ),
            runtime: fixture.runtime(
                history: history.access(),
                assets: TranscriptionRetryAssetRecorder().access(),
                jobStore: failingStore
            )
        )

        try await waitUntil { events.outcomes.count == 1 }
        let completion = try requireSuccessCompletion(events.outcomes.last)
        try expect(!history.persistedItems.isEmpty, "durable item survives cleanup failure")
        try expect(
            completion.cleanupFailureDescription?.isEmpty == false,
            "cleanup failure is surfaced"
        )
    }

    @MainActor
    private static func testInvalidateRejectsLateSuccess() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let item = makeHistoryItem()
        let history = TranscriptionRetryHistoryRecorder(item: item)
        let events = TranscriptionRetryEventRecorder()
        let gate = TranscriptionRetryControlledTranscriber()
        let workflow = TranscriptionRetryWorkflow(
            dependencies: TranscriptionRetryWorkflowDependencies(
                transcribe: { _, _, _, context in
                    try await gate.run(context: context)
                },
                makeAttemptToken: { UUID() }
            )
        )
        workflow.onEvent = events.record

        _ = workflow.startManual(
            request: try makeRequest(item: item, fixture: fixture),
            runtime: fixture.runtime(
                history: history.access(),
                assets: TranscriptionRetryAssetRecorder().access()
            )
        )
        await gate.waitUntilStarted()
        workflow.invalidate(noteID: item.id)

        try expectEqual(workflow.state, .initial, "invalidate clears state")
        try expect(events.outcomes.contains(.cancelled), "invalidate cancellation outcome")
        await gate.succeed(transcriptionResult(text: "late success"))
        await drainTasks()
        try expect(history.persistedItems.isEmpty, "late success not persisted")
        try expect(events.persistedEvents.isEmpty, "late success has no item event")
    }

    @MainActor
    private static func testCancelRejectsLateFailureAndClearsState()
        async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let item = makeHistoryItem()
        let history = TranscriptionRetryHistoryRecorder(item: item)
        let events = TranscriptionRetryEventRecorder()
        let gate = TranscriptionRetryControlledTranscriber()
        let workflow = TranscriptionRetryWorkflow(
            dependencies: TranscriptionRetryWorkflowDependencies(
                transcribe: { _, _, _, context in
                    try await gate.run(context: context)
                },
                makeAttemptToken: { UUID() }
            )
        )
        workflow.onEvent = events.record

        _ = workflow.startManual(
            request: try makeRequest(item: item, fixture: fixture),
            runtime: fixture.runtime(
                history: history.access(),
                assets: TranscriptionRetryAssetRecorder().access()
            )
        )
        await gate.waitUntilStarted()
        workflow.cancel(noteID: item.id)

        try expectEqual(workflow.state, .initial, "cancel clears state")
        await gate.fail(TranscriptionRetryInjectedError.provider)
        await drainTasks()
        try expect(history.persistedItems.isEmpty, "late failure not persisted")
        try expect(events.persistedEvents.isEmpty, "late failure has no item event")
        try expect(events.outcomes.contains(.cancelled), "cancel outcome")
    }

    @MainActor
    private static func testCancellationDuringPostProcessingEmitsOneTerminalOutcome()
        async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let item = makeHistoryItem()
        let history = TranscriptionRetryHistoryRecorder(item: item)
        let events = TranscriptionRetryEventRecorder()
        let processingGate = TranscriptionRetryControlledTranscriber()
        let workflow = TranscriptionRetryWorkflow(
            dependencies: immediateDependencies(text: "provider raw")
        )
        workflow.onEvent = events.record
        let processing = TranscriptionRetryProcessingBehavior { _ in
            _ = try? await processingGate.run(
                context: nil,
                emitsProgress: false
            )
            return processingResult(
                raw: "processed raw",
                final: "processed final"
            )
        }

        _ = workflow.startManual(
            request: try makeRequest(
                item: item,
                fixture: fixture,
                processing: processing
            ),
            runtime: fixture.runtime(
                history: history.access(),
                assets: TranscriptionRetryAssetRecorder().access()
            )
        )
        await processingGate.waitUntilStarted()
        workflow.cancel(noteID: item.id)
        await processingGate.succeed(
            transcriptionResult(text: "processing released")
        )
        await drainTasks()

        try expectEqual(
            events.outcomes,
            [.cancelled],
            "post-processing cancellation terminal outcome"
        )
        try expect(history.persistedItems.isEmpty, "cancelled processing not persisted")
        try expect(events.persistedEvents.isEmpty, "cancelled processing has no item event")
    }

    @MainActor
    private static func testForgetRemovesNoteState() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let item = makeHistoryItem()
        let history = TranscriptionRetryHistoryRecorder(item: item)
        let events = TranscriptionRetryEventRecorder()
        let gate = TranscriptionRetryControlledTranscriber()
        let workflow = TranscriptionRetryWorkflow(
            dependencies: TranscriptionRetryWorkflowDependencies(
                transcribe: { _, _, _, context in
                    try await gate.run(context: context)
                },
                makeAttemptToken: { UUID() }
            )
        )
        workflow.onEvent = events.record

        _ = workflow.startManual(
            request: try makeRequest(item: item, fixture: fixture),
            runtime: fixture.runtime(
                history: history.access(),
                assets: TranscriptionRetryAssetRecorder().access()
            )
        )
        await gate.waitUntilStarted()
        workflow.forget(noteID: item.id)
        await gate.succeed(transcriptionResult(text: "forgotten success"))
        await drainTasks()

        try expectEqual(workflow.state, .initial, "forget clears note state")
        try expect(history.persistedItems.isEmpty, "forgotten completion rejected")
    }

    @MainActor
    private static func testForgetAllRejectsEveryLateCompletion() async throws {
        let firstFixture = try makeFixture()
        let secondFixture = try makeFixture()
        defer {
            firstFixture.cleanup()
            secondFixture.cleanup()
        }
        let firstItem = makeHistoryItem()
        let secondItem = makeHistoryItem()
        let firstHistory = TranscriptionRetryHistoryRecorder(item: firstItem)
        let secondHistory = TranscriptionRetryHistoryRecorder(item: secondItem)
        let events = TranscriptionRetryEventRecorder()
        let controlled = TranscriptionRetryMultiControlledTranscriber()
        let workflow = TranscriptionRetryWorkflow(
            dependencies: TranscriptionRetryWorkflowDependencies(
                transcribe: { _, _, _, context in
                    try await controlled.run(context: context)
                },
                makeAttemptToken: { UUID() }
            )
        )
        workflow.onEvent = events.record

        _ = workflow.startManual(
            request: try makeRequest(item: firstItem, fixture: firstFixture),
            runtime: firstFixture.runtime(
                history: firstHistory.access(),
                assets: TranscriptionRetryAssetRecorder().access()
            )
        )
        _ = workflow.startManual(
            request: try makeRequest(item: secondItem, fixture: secondFixture),
            runtime: secondFixture.runtime(
                history: secondHistory.access(),
                assets: TranscriptionRetryAssetRecorder().access()
            )
        )
        await controlled.waitUntilCallCount(2)
        workflow.forgetAll()
        await controlled.succeed(call: 0, result: transcriptionResult(text: "first late"))
        await controlled.succeed(call: 1, result: transcriptionResult(text: "second late"))
        await drainTasks()

        try expectEqual(workflow.state, .initial, "forget all clears state")
        try expect(firstHistory.persistedItems.isEmpty, "first late completion rejected")
        try expect(secondHistory.persistedItems.isEmpty, "second late completion rejected")
    }

    @MainActor
    private static func testNewerAttemptRejectsOlderSuccessAndProgress()
        async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let item = makeHistoryItem()
        let history = TranscriptionRetryHistoryRecorder(item: item)
        let events = TranscriptionRetryEventRecorder()
        let controlled = TranscriptionRetryMultiControlledTranscriber()
        let tokens = TranscriptionRetryTokenSource()
        let workflow = TranscriptionRetryWorkflow(
            dependencies: TranscriptionRetryWorkflowDependencies(
                transcribe: { _, _, _, context in
                    try await controlled.run(context: context)
                },
                makeAttemptToken: { tokens.next() }
            )
        )
        workflow.onEvent = events.record
        let request = try makeRequest(
            item: item,
            fixture: fixture,
            processing: processingBehaviorFromTranscription()
        )
        let runtime = fixture.runtime(
            history: history.access(),
            assets: TranscriptionRetryAssetRecorder().access()
        )

        _ = workflow.startManual(request: request, runtime: runtime)
        await controlled.waitUntilCallCount(1)
        _ = workflow.startManual(request: request, runtime: runtime)
        await controlled.waitUntilCallCount(2)
        await controlled.emitProgress(
            call: 1,
            progress: .uploading(index: 2, total: 4, attempt: 1)
        )
        try await waitUntil {
            workflow.state.progressByNoteID[item.id]?.completedChunkCount == 2
        }
        await controlled.emitProgress(
            call: 0,
            progress: .uploading(index: 3, total: 4, attempt: 9)
        )
        await drainTasks()
        try expectEqual(
            workflow.state.progressByNoteID[item.id],
            CloudTranscriptionDisplayProgress(
                completedChunkCount: 2,
                totalChunkCount: 4,
                activeAttempt: 1
            ),
            "older progress rejected"
        )
        await controlled.succeed(
            call: 0,
            result: transcriptionResult(text: "older success")
        )
        await drainTasks()
        try expect(history.persistedItems.isEmpty, "older success rejected")
        try expect(workflow.state.retryingNoteIDs.contains(item.id), "newer state retained")

        await controlled.succeed(
            call: 1,
            result: transcriptionResult(text: "newer success")
        )
        try await waitUntil { history.persistedItems.count == 1 }
        try expectEqual(
            history.persistedItems.last?.rawTranscript,
            "newer success",
            "newer success persisted"
        )
        try expectEqual(workflow.state, .initial, "newer attempt finished")
    }

    @MainActor
    private static func testNewerAttemptRejectsOlderFailure() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let item = makeHistoryItem()
        let history = TranscriptionRetryHistoryRecorder(item: item)
        let events = TranscriptionRetryEventRecorder()
        let controlled = TranscriptionRetryMultiControlledTranscriber()
        let tokens = TranscriptionRetryTokenSource()
        let workflow = TranscriptionRetryWorkflow(
            dependencies: TranscriptionRetryWorkflowDependencies(
                transcribe: { _, _, _, context in
                    try await controlled.run(context: context)
                },
                makeAttemptToken: { tokens.next() }
            )
        )
        workflow.onEvent = events.record
        let request = try makeRequest(
            item: item,
            fixture: fixture,
            processing: processingBehaviorFromTranscription()
        )
        let runtime = fixture.runtime(
            history: history.access(),
            assets: TranscriptionRetryAssetRecorder().access()
        )

        _ = workflow.startManual(request: request, runtime: runtime)
        await controlled.waitUntilCallCount(1)
        _ = workflow.startManual(request: request, runtime: runtime)
        await controlled.waitUntilCallCount(2)
        await controlled.fail(
            call: 0,
            error: TranscriptionRetryInjectedError.provider
        )
        await drainTasks()
        try expect(history.persistedItems.isEmpty, "older failure rejected")
        try expect(events.persistedEvents.isEmpty, "older failure has no item event")
        try expect(workflow.state.retryingNoteIDs.contains(item.id), "newer attempt active")

        await controlled.succeed(
            call: 1,
            result: transcriptionResult(text: "newer success")
        )
        try await waitUntil { history.persistedItems.count == 1 }
        try expectEqual(
            history.persistedItems.last?.rawTranscript,
            "newer success",
            "newer result after old failure"
        )
    }

    @MainActor
    private static func testChangedAudioIdentityRejectsCompletion() async throws {
        try await assertChangedSourceRejectsCompletion(change: .audioFileName)
    }

    @MainActor
    private static func testChangedTimestampRejectsCompletion() async throws {
        try await assertChangedSourceRejectsCompletion(change: .timestamp)
    }

    @MainActor
    private static func assertChangedSourceRejectsCompletion(
        change: TranscriptionRetrySourceChange
    ) async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let item = makeHistoryItem()
        let history = TranscriptionRetryHistoryRecorder(item: item)
        let events = TranscriptionRetryEventRecorder()
        let gate = TranscriptionRetryControlledTranscriber()
        let assets = TranscriptionRetryAssetRecorder()
        let workflow = TranscriptionRetryWorkflow(
            dependencies: TranscriptionRetryWorkflowDependencies(
                transcribe: { _, _, _, context in
                    try await gate.run(context: context)
                },
                makeAttemptToken: { UUID() }
            )
        )
        workflow.onEvent = events.record

        _ = workflow.startManual(
            request: try makeRequest(item: item, fixture: fixture),
            runtime: fixture.runtime(
                history: history.access(),
                assets: assets.access()
            )
        )
        await gate.waitUntilStarted()
        history.currentItem = change.changedItem(from: item)
        await gate.succeed(transcriptionResult(text: "stale source"))
        try await waitUntil { events.outcomes.contains(.stale) }

        try expect(history.persistedItems.isEmpty, "changed source not persisted")
        try expect(events.persistedEvents.isEmpty, "changed source has no item event")
        try expect(assets.saved().isEmpty, "changed source creates no transcript")
    }

    @MainActor
    private static func testStaleAttemptDeletesOnlyItsCreatedTranscript()
        async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let item = makeHistoryItem()
        let assets = TranscriptionRetryAssetRecorder()
        let events = TranscriptionRetryEventRecorder()
        let workflow = TranscriptionRetryWorkflow(
            dependencies: immediateDependencies(text: "provider raw")
        )
        workflow.onEvent = events.record
        let history = TranscriptionRetryHistoryAccess(
            durability: { .durable },
            item: { id in
                guard id == item.id else { return nil }
                workflow.invalidate(noteID: id)
                return item
            },
            persist: { _, _ in
                throw TranscriptionRetryWorkflowTestFailure(
                    "stale attempt must not persist"
                )
            }
        )

        _ = workflow.startManual(
            request: try makeRequest(item: item, fixture: fixture),
            runtime: fixture.runtime(
                history: history,
                assets: assets.access()
            )
        )

        try await waitUntil { assets.deleted() == ["created.txt"] }
        try expectEqual(assets.saved(), ["created.txt"], "stale created transcript")
        try expectEqual(assets.deleted(), ["created.txt"], "stale cleanup transcript")
        try expectEqual(
            events.outcomes,
            [.cancelled],
            "stale asset emits only the cancellation terminal outcome"
        )
        try expect(events.persistedEvents.isEmpty, "stale asset has no item event")
    }

    private static func testStartupFilterResumesOnlyExactCompatibleRecords()
        throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let runtimeConfiguration = defaultCloudConfiguration(fixture: fixture)
        let runtimeState = try makeCloudState(
            historyID: UUID(),
            fixture: fixture,
            configuration: runtimeConfiguration
        )
        let runtime = try requireCloudRuntime(runtimeState.execution)
        let firstCompatible = try makeCloudState(
            historyID: UUID(),
            fixture: fixture,
            configuration: runtimeConfiguration
        ).record
        let secondCompatible = try makeCloudState(
            historyID: UUID(),
            fixture: fixture,
            configuration: runtimeConfiguration
        ).record
        let startupMismatches = TranscriptionRetryCloudMismatch.allCases.filter {
            $0 != .completionPolicy
        }
        let incompatible = try startupMismatches.map {
            try makeCloudState(
                historyID: UUID(),
                fixture: fixture,
                configuration: $0.applying(
                    to: runtimeConfiguration,
                    fixture: fixture
                )
            ).record
        }
        let oldAlgorithm = replacingAlgorithmVersion(
            in: try makeCloudState(
                historyID: UUID(),
                fixture: fixture,
                configuration: runtimeConfiguration
            ).record,
            with: 0
        )
        let terminal = try makeCloudState(
            historyID: UUID(),
            fixture: fixture,
            configuration: runtimeConfiguration
        ).record
        let invalidID = UUID()
        let base = CloudTranscriptionReconciliation(
            resumable: [firstCompatible, secondCompatible]
                + incompatible
                + [oldAlgorithm],
            waitingForRetry: [terminal],
            invalid: [invalidID]
        )
        let result = CloudTranscriptionStartupReconciler(
            store: fixture.jobStore,
            audioRoot: fixture.audioURL.deletingLastPathComponent()
        ).reconcile(base, runtime: runtime)

        try expectEqual(
            Set(result.resumable.map(\.historyID)),
            Set([firstCompatible.historyID, secondCompatible.historyID]),
            "startup exact compatibility"
        )
        try expectEqual(
            Set(result.waitingForRetry.map(\.historyID)),
            Set(incompatible.map(\.historyID) + [
                oldAlgorithm.historyID,
                terminal.historyID
            ]),
            "startup incompatible records wait"
        )
        try expectEqual(result.invalid, [invalidID], "startup invalid IDs")
    }

    private static func testStartupFilterPreservesKeylessAndIncompatibleRecordsForRetry()
        throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let configuration = defaultCloudConfiguration(fixture: fixture)
        let record = try makeCloudState(
            historyID: UUID(),
            fixture: fixture,
            configuration: configuration
        ).record
        var keylessConfiguration = configuration
        keylessConfiguration.apiKey = "   "
        let keylessRuntime = try requireCloudRuntime(
            makeCloudState(
                historyID: UUID(),
                fixture: fixture,
                configuration: keylessConfiguration
            ).execution
        )
        let invalidID = UUID()
        let base = CloudTranscriptionReconciliation(
            resumable: [record],
            waitingForRetry: [],
            invalid: [invalidID]
        )
        let result = CloudTranscriptionStartupReconciler(
            store: fixture.jobStore,
            audioRoot: fixture.audioURL.deletingLastPathComponent()
        ).reconcile(base, runtime: keylessRuntime)

        try expect(result.resumable.isEmpty, "keyless startup does not resume")
        try expectEqual(result.waitingForRetry, [record], "keyless record preserved")
        try expectEqual(result.invalid, [invalidID], "keyless invalid IDs preserved")
    }

    @MainActor
    private static func testStartupResumeUsesPersistedCompletionPolicy()
        async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let item = makeHistoryItem()
        var configuration = defaultCloudConfiguration(fixture: fixture)
        configuration.completionPolicy = CloudTranscriptionCompletionPolicy(
            postProcessingEnabled: false,
            outputLanguage: "ko",
            pressEnterCommandEnabled: true
        )
        let cloud = try makeCloudState(
            historyID: item.id,
            fixture: fixture,
            configuration: configuration,
            completedPrefix: ["stored prefix"]
        )
        try createStoredRecord(cloud.record, in: fixture.jobStore)
        let processing = TranscriptionRetryStartupProcessingRecorder(
            result: processingResult(raw: "resumed raw", final: "resumed final")
        )
        let history = TranscriptionRetryHistoryRecorder(item: item)
        let events = TranscriptionRetryEventRecorder()
        let workflow = TranscriptionRetryWorkflow(
            dependencies: immediateDependencies(text: "provider resumed")
        )
        workflow.onEvent = events.record

        workflow.resumeAtStartup(
            input: try makeStartupInput(
                cloud: cloud,
                item: item,
                fixture: fixture,
                processing: processing
            ),
            runtime: fixture.runtime(
                history: history.access(),
                assets: TranscriptionRetryAssetRecorder().access()
            )
        )

        try await waitUntil { events.outcomes.count == 1 }
        try expectEqual(
            processing.completions,
            [
                TranscriptionCompletionSnapshot(
                    postProcessingEnabled: false,
                    outputLanguage: "ko",
                    pressEnterCommandEnabled: true
                )
            ],
            "startup persisted completion"
        )
    }

    @MainActor
    private static func testStartupResumeUsesStoredContextAndHistoryOnlyDelivery()
        async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let item = makeHistoryItem(contextSummary: "stored startup context")
        let cloud = try makeCloudState(
            historyID: item.id,
            fixture: fixture,
            configuration: defaultCloudConfiguration(fixture: fixture)
        )
        try createStoredRecord(cloud.record, in: fixture.jobStore)
        let processing = TranscriptionRetryStartupProcessingRecorder(
            result: processingResult(raw: "resumed raw", final: "resumed final")
        )
        let history = TranscriptionRetryHistoryRecorder(item: item)
        let events = TranscriptionRetryEventRecorder()
        let workflow = TranscriptionRetryWorkflow(
            dependencies: immediateDependencies(text: "provider resumed")
        )
        workflow.onEvent = events.record

        workflow.resumeAtStartup(
            input: try makeStartupInput(
                cloud: cloud,
                item: item,
                fixture: fixture,
                processing: processing
            ),
            runtime: fixture.runtime(
                history: history.access(),
                assets: TranscriptionRetryAssetRecorder().access()
            )
        )

        try await waitUntil { events.outcomes.count == 1 }
        try expectEqual(
            processing.items.first?.contextSummary,
            "stored startup context",
            "startup stored context"
        )
        let completion = try requireSuccessCompletion(events.outcomes.last)
        try expect(completion.interactiveTranscript == nil, "startup is history only")
    }

    @MainActor
    private static func testStartupDuplicateHistoryIDsUseFirstItem()
        async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let item = makeHistoryItem(contextSummary: "first stored context")
        let duplicate = makeHistoryItem(
            id: item.id,
            timestamp: item.timestamp,
            audioFileName: item.audioFileName ?? "recording.wav",
            contextSummary: "duplicate stored context"
        )
        let cloud = try makeCloudState(
            historyID: item.id,
            fixture: fixture,
            configuration: defaultCloudConfiguration(fixture: fixture)
        )
        try createStoredRecord(cloud.record, in: fixture.jobStore)
        let processing = TranscriptionRetryStartupProcessingRecorder(
            result: processingResult(raw: "resumed raw", final: "resumed final")
        )
        let history = TranscriptionRetryHistoryRecorder(item: item)
        let events = TranscriptionRetryEventRecorder()
        let workflow = TranscriptionRetryWorkflow(
            dependencies: immediateDependencies(text: "provider resumed")
        )
        workflow.onEvent = events.record

        workflow.resumeAtStartup(
            input: try makeStartupInput(
                cloud: cloud,
                item: item,
                fixture: fixture,
                processing: processing,
                history: [item, duplicate]
            ),
            runtime: fixture.runtime(
                history: history.access(),
                assets: TranscriptionRetryAssetRecorder().access()
            )
        )

        try await waitUntil { events.outcomes.count == 1 }
        try expectEqual(
            processing.items.first?.contextSummary,
            "first stored context",
            "duplicate startup history keeps first item"
        )
    }

    @MainActor
    private static func testStartupSuccessPersistsAndDeletesSidecar()
        async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let item = makeHistoryItem()
        let cloud = try makeCloudState(
            historyID: item.id,
            fixture: fixture,
            configuration: defaultCloudConfiguration(fixture: fixture),
            completedPrefix: ["stored prefix"]
        )
        try createStoredRecord(cloud.record, in: fixture.jobStore)
        let processing = TranscriptionRetryStartupProcessingRecorder(
            result: processingResult(raw: "resumed raw", final: "resumed final")
        )
        let history = TranscriptionRetryHistoryRecorder(item: item)
        let events = TranscriptionRetryEventRecorder()
        let dependencyCount = TranscriptionRetryCounter()
        let workflow = TranscriptionRetryWorkflow(
            dependencies: immediateDependencies(text: "provider resumed")
        )
        workflow.onEvent = events.record

        workflow.resumeAtStartup(
            input: try makeStartupInput(
                cloud: cloud,
                item: item,
                fixture: fixture,
                processing: processing,
                dependencyCount: dependencyCount
            ),
            runtime: fixture.runtime(
                history: history.access(),
                assets: TranscriptionRetryAssetRecorder().access()
            )
        )

        try await waitUntil { events.outcomes.count == 1 }
        try expectEqual(
            history.persistedItems.last?.postProcessedTranscript,
            "resumed final",
            "startup persisted transcript"
        )
        try expectEqual(
            events.persistedEvents.last?.effects,
            TranscriptionRetryPersistedEffects(
                advancesWarningGeneration: true,
                invalidatesMeetingSummary: false
            ),
            "startup persisted effects"
        )
        try expectEqual(dependencyCount.value(), 1, "one startup dependency value")
        let remainingSidecar = try fixture.jobStore.load(historyID: item.id)
        try expect(
            remainingSidecar == nil,
            "startup success deletes sidecar"
        )
    }

    @MainActor
    private static func testStartupFallbackPersistsWithoutSummaryInvalidation()
        async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let item = makeHistoryItem()
        let cloud = try makeCloudState(
            historyID: item.id,
            fixture: fixture,
            configuration: defaultCloudConfiguration(fixture: fixture)
        )
        try createStoredRecord(cloud.record, in: fixture.jobStore)
        let processing = TranscriptionRetryStartupProcessingRecorder(
            result: processingResult(
                raw: "startup fallback",
                final: "startup fallback",
                disposition: .fallback,
                outcome: .failed(reason: "request-timed-out")
            )
        )
        let history = TranscriptionRetryHistoryRecorder(item: item)
        let events = TranscriptionRetryEventRecorder()
        let workflow = TranscriptionRetryWorkflow(
            dependencies: immediateDependencies(text: "provider resumed")
        )
        workflow.onEvent = events.record

        workflow.resumeAtStartup(
            input: try makeStartupInput(
                cloud: cloud,
                item: item,
                fixture: fixture,
                processing: processing
            ),
            runtime: fixture.runtime(
                history: history.access(),
                assets: TranscriptionRetryAssetRecorder().access()
            )
        )

        try await waitUntil { events.outcomes.count == 1 }
        guard case .fallback(let completion)? = events.outcomes.last else {
            throw TranscriptionRetryWorkflowTestFailure("startup fallback outcome")
        }
        try expect(completion.interactiveTranscript == nil, "startup fallback history only")
        try expectEqual(
            events.persistedEvents.last?.effects.invalidatesMeetingSummary,
            false,
            "startup fallback Summary effect"
        )
    }

    @MainActor
    private static func testStartupProviderFailurePreservesPlaceholderAndSidecar()
        async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let item = makeHistoryItem(
            rawTranscript: "",
            postProcessedTranscript: ""
        )
        let cloud = try makeCloudState(
            historyID: item.id,
            fixture: fixture,
            configuration: defaultCloudConfiguration(fixture: fixture),
            completedPrefix: ["stored prefix"]
        )
        try createStoredRecord(cloud.record, in: fixture.jobStore)
        let processing = TranscriptionRetryStartupProcessingRecorder(
            result: processingResult()
        )
        let history = TranscriptionRetryHistoryRecorder(item: item)
        let events = TranscriptionRetryEventRecorder()
        let workflow = TranscriptionRetryWorkflow(
            dependencies: failingDependencies(
                TranscriptionRetryInjectedError.provider
            )
        )
        workflow.onEvent = events.record

        workflow.resumeAtStartup(
            input: try makeStartupInput(
                cloud: cloud,
                item: item,
                fixture: fixture,
                processing: processing
            ),
            runtime: fixture.runtime(
                history: history.access(),
                assets: TranscriptionRetryAssetRecorder().access()
            )
        )

        try await waitUntil { events.outcomes.count == 1 }
        guard case .failed(let failure)? = events.outcomes.last else {
            throw TranscriptionRetryWorkflowTestFailure("startup failure outcome")
        }
        try expect(!failure.historyPersisted, "startup failure not persisted")
        try expect(history.persistedItems.isEmpty, "startup placeholder unchanged")
        try expectEqual(
            try fixture.jobStore.load(historyID: item.id),
            cloud.record,
            "startup failure sidecar"
        )
    }

    @MainActor
    private static func testStartupCancellationPreservesPlaceholderAndSidecar()
        async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let item = makeHistoryItem(rawTranscript: "", postProcessedTranscript: "")
        let cloud = try makeCloudState(
            historyID: item.id,
            fixture: fixture,
            configuration: defaultCloudConfiguration(fixture: fixture),
            completedPrefix: ["stored prefix"]
        )
        try createStoredRecord(cloud.record, in: fixture.jobStore)
        let processing = TranscriptionRetryStartupProcessingRecorder(
            result: processingResult()
        )
        let history = TranscriptionRetryHistoryRecorder(item: item)
        let events = TranscriptionRetryEventRecorder()
        let gate = TranscriptionRetryControlledTranscriber()
        let workflow = TranscriptionRetryWorkflow(
            dependencies: TranscriptionRetryWorkflowDependencies(
                transcribe: { _, _, _, context in
                    try await gate.run(
                        context: context,
                        emitsProgress: false
                    )
                },
                makeAttemptToken: { UUID() }
            )
        )
        workflow.onEvent = events.record

        workflow.resumeAtStartup(
            input: try makeStartupInput(
                cloud: cloud,
                item: item,
                fixture: fixture,
                processing: processing
            ),
            runtime: fixture.runtime(
                history: history.access(),
                assets: TranscriptionRetryAssetRecorder().access()
            )
        )
        await gate.waitUntilStarted()
        workflow.cancel(noteID: item.id)
        await gate.succeed(transcriptionResult(text: "late startup"))
        await drainTasks()

        try expect(history.persistedItems.isEmpty, "startup cancellation not persisted")
        try expectEqual(
            try fixture.jobStore.load(historyID: item.id),
            cloud.record,
            "startup cancellation sidecar"
        )
    }

    @MainActor
    private static func testStartupMissingHistoryDoesNotStartProvider()
        async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let item = makeHistoryItem()
        let cloud = try makeCloudState(
            historyID: item.id,
            fixture: fixture,
            configuration: defaultCloudConfiguration(fixture: fixture)
        )
        let processing = TranscriptionRetryStartupProcessingRecorder(
            result: processingResult()
        )
        let invocation = TranscriptionRetryInvocationRecorder()
        let missingHistory = TranscriptionRetryHistoryRecorder(item: nil)
        let workflow = TranscriptionRetryWorkflow(
            dependencies: TranscriptionRetryWorkflowDependencies(
                transcribe: { execution, _, dependencies, _ in
                    await invocation.record(
                        execution: execution,
                        dependencies: dependencies
                    )
                    return transcriptionResult(text: "must not start")
                },
                makeAttemptToken: { UUID() }
            )
        )

        workflow.resumeAtStartup(
            input: try makeStartupInput(
                cloud: cloud,
                item: item,
                fixture: fixture,
                processing: processing,
                history: []
            ),
            runtime: fixture.runtime(
                history: missingHistory.access(),
                assets: TranscriptionRetryAssetRecorder().access()
            )
        )
        await drainTasks()

        try expectEqual(await invocation.count(), 0, "missing startup provider")
        try expectEqual(workflow.state, .initial, "missing startup state")
    }

    @MainActor
    private static func testStartupSeedsAndClearsStoredProgress()
        async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let item = makeHistoryItem()
        let cloud = try makeCloudState(
            historyID: item.id,
            fixture: fixture,
            configuration: defaultCloudConfiguration(fixture: fixture),
            completedPrefix: ["stored prefix"]
        )
        try createStoredRecord(cloud.record, in: fixture.jobStore)
        let processing = TranscriptionRetryStartupProcessingRecorder(
            result: processingResult(raw: "resumed", final: "resumed")
        )
        let history = TranscriptionRetryHistoryRecorder(item: item)
        let events = TranscriptionRetryEventRecorder()
        let gate = TranscriptionRetryControlledTranscriber()
        let workflow = TranscriptionRetryWorkflow(
            dependencies: TranscriptionRetryWorkflowDependencies(
                transcribe: { _, _, _, context in
                    try await gate.run(
                        context: context,
                        emitsProgress: false
                    )
                },
                makeAttemptToken: { UUID() }
            )
        )
        workflow.onEvent = events.record

        workflow.resumeAtStartup(
            input: try makeStartupInput(
                cloud: cloud,
                item: item,
                fixture: fixture,
                processing: processing
            ),
            runtime: fixture.runtime(
                history: history.access(),
                assets: TranscriptionRetryAssetRecorder().access()
            )
        )
        await gate.waitUntilStarted()
        try await waitUntil {
            workflow.state.progressByNoteID[item.id] != nil
        }
        try expectEqual(
            workflow.state.progressByNoteID[item.id],
            CloudTranscriptionDisplayProgress(
                completedChunkCount: cloud.record.completedChunks.count,
                totalChunkCount: cloud.record.plan.chunks.count,
                activeAttempt: nil
            ),
            "startup seeded progress"
        )
        await gate.succeed(transcriptionResult(text: "resumed"))
        try await waitUntil { events.outcomes.count == 1 }
        try expect(workflow.state.progressByNoteID[item.id] == nil, "startup progress cleared")
    }

    nonisolated private static func fakeLocalAISnapshot(
        digest: String = "digest"
    ) -> LocalAITranscriptionExecutionSnapshot {
        LocalAITranscriptionExecutionSnapshot(
            modelID: "gemma-4-e4b-it",
            displayName: "Gemma 4 E4B",
            packageDigest: digest,
            requestFormat: .chatCompletionsInputAudio,
            modelIsReady: { true },
            prepareAudio: { url in .init(fileURL: url, cleanup: {}) },
            transcribeChunk: { _, _, _ in "unused" }
        )
    }

    nonisolated private static func makeLocalAIExecution(
        digest: String = "digest"
    ) -> LocalTranscriptionExecutionSnapshot {
        LocalTranscriptionExecutionSnapshot(
            model: .default,
            localWhisperPath: nil,
            useLegacyMlxWhisper: false,
            language: .find(code: "en"),
            localAIExecution: fakeLocalAISnapshot(digest: digest)
        )
    }

    private static func makeLocalAIRecord(
        historyID: UUID,
        fixture: TranscriptionRetryFixture
    ) throws -> CloudTranscriptionJobRecord {
        let cloud = try makeCloudState(
            historyID: historyID,
            fixture: fixture,
            configuration: defaultCloudConfiguration(fixture: fixture),
            completedPrefix: ["stored local prefix"]
        )
        var plan = cloud.record.plan
        plan.sizing = .rawWAV
        plan.silenceSearchFrameCount = LocalTranscriptionChunkLimits.silenceSearchFrameCount
        let local = fakeLocalAISnapshot()
        let identity = local.resumeIdentity(language: "en")
        let localPlan = CloudTranscriptionChunkPlan(
            algorithmVersion: plan.algorithmVersion,
            encodedUploadCeilingBytes: identity.ceilingBytes,
            sourceFrameCount: plan.sourceFrameCount,
            chunks: plan.chunks,
            planID: "local-" + plan.planID,
            sizing: .rawWAV,
            silenceSearchFrameCount: identity.silenceSearchFrameCount
        )
        return CloudTranscriptionJobRecord(
            schemaVersion: CloudTranscriptionJobRecord.currentSchemaVersion,
            historyID: historyID,
            createdAt: cloud.record.createdAt,
            updatedAt: cloud.record.updatedAt,
            phase: cloud.record.phase,
            identity: CloudTranscriptionJobIdentity(
                providerID: identity.providerID,
                model: identity.model,
                language: identity.language,
                responseFormat: identity.responseFormat,
                source: cloud.record.identity.source,
                planID: localPlan.planID
            ),
            plan: localPlan,
            completedChunks: cloud.record.completedChunks,
            firstIncompleteChunkIndex: cloud.record.firstIncompleteChunkIndex,
            lastFailure: nil,
            completionPolicy: cloud.record.completionPolicy
        )
    }

    @MainActor
    private static func testLocalAIManualRetryGetsJobStoreContext() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let item = makeHistoryItem()
        let invocation = TranscriptionRetryLocalContextRecorder()
        await invocation.record(contextWasNil: true)
        let history = TranscriptionRetryHistoryRecorder(item: item)
        let events = TranscriptionRetryEventRecorder()
        let workflow = TranscriptionRetryWorkflow(
            dependencies: TranscriptionRetryWorkflowDependencies(
                transcribe: { _, _, _, context in
                    await invocation.record(contextWasNil: context == nil)
                    return transcriptionResult(text: "local ai")
                },
                makeAttemptToken: { UUID() }
            )
        )
        workflow.onEvent = events.record

        _ = workflow.startManual(
            request: try makeRequest(
                item: item,
                fixture: fixture,
                execution: .local(
                    makeLocalAIExecution(),
                    TranscriptionCompletionSnapshot(
                        postProcessingEnabled: true,
                        outputLanguage: "en",
                        pressEnterCommandEnabled: false
                    )
                ),
                processing: processingBehaviorFromTranscription(),
                historyMetadata: localHistoryMetadata(),
                failureContext: localFailureContext()
            ),
            runtime: fixture.runtime(
                history: history.access(),
                assets: TranscriptionRetryAssetRecorder().access()
            )
        )

        try await waitUntil { events.outcomes.count == 1 }
        let contextWasNil = await invocation.contextWasNil()
        try expect(!contextWasNil, "Local AI retry gets a job-store context")
    }

    @MainActor
    private static func testLocalAIStartupResumeUsesLocalExecution() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let item = makeHistoryItem()
        let record = try makeLocalAIRecord(historyID: item.id, fixture: fixture)
        try createStoredRecord(record, in: fixture.jobStore)
        let captured = TranscriptionRetryExecutionRecorder()
        let history = TranscriptionRetryHistoryRecorder(item: item)
        let events = TranscriptionRetryEventRecorder()
        let workflow = TranscriptionRetryWorkflow(
            dependencies: TranscriptionRetryWorkflowDependencies(
                transcribe: { execution, _, _, context in
                    await captured.record(execution: execution, hasContext: context != nil)
                    return transcriptionResult(text: "resumed local")
                },
                makeAttemptToken: { UUID() }
            )
        )
        workflow.onEvent = events.record
        let processing = TranscriptionRetryStartupProcessingRecorder(
            result: processingResult(raw: "resumed local", final: "resumed local")
        )
        let local = fakeLocalAISnapshot()

        workflow.resumeAtStartup(
            input: try makeLocalAIStartupInput(
                record: record,
                item: item,
                fixture: fixture,
                processing: processing,
                localIdentity: local.resumeIdentity(language: "en")
            ),
            runtime: fixture.runtime(
                history: history.access(),
                assets: TranscriptionRetryAssetRecorder().access()
            )
        )

        try await waitUntil { events.outcomes.count == 1 }
        let summary = await captured.summary()
        try expectEqual(summary, ["local-ai:digest context:true"], "local execution with context")
        try expectEqual(
            history.persistedItems.last?.usedLocalTranscription,
            true,
            "resume records local transcription"
        )
    }

    @MainActor
    private static func testLocalAIRecordWaitsWhenLocalModelChanged() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let item = makeHistoryItem()
        let record = try makeLocalAIRecord(historyID: item.id, fixture: fixture)
        try createStoredRecord(record, in: fixture.jobStore)
        let captured = TranscriptionRetryExecutionRecorder()
        let workflow = TranscriptionRetryWorkflow(
            dependencies: TranscriptionRetryWorkflowDependencies(
                transcribe: { execution, _, _, context in
                    await captured.record(execution: execution, hasContext: context != nil)
                    return transcriptionResult(text: "must not run")
                },
                makeAttemptToken: { UUID() }
            )
        )
        let changed = fakeLocalAISnapshot(digest: "other")

        workflow.resumeAtStartup(
            input: try makeLocalAIStartupInput(
                record: record,
                item: item,
                fixture: fixture,
                processing: TranscriptionRetryStartupProcessingRecorder(
                    result: processingResult(raw: "x", final: "x")
                ),
                localIdentity: changed.resumeIdentity(language: "en"),
                localDigest: "other"
            ),
            runtime: fixture.runtime(
                history: TranscriptionRetryHistoryRecorder(item: item).access(),
                assets: TranscriptionRetryAssetRecorder().access()
            )
        )

        try await Task.sleep(nanoseconds: 200_000_000)
        let summary = await captured.summary()
        try expectEqual(summary, [], "changed package does not resume")
    }

    private static func makeLocalAIStartupInput(
        record: CloudTranscriptionJobRecord,
        item: PipelineHistoryItem,
        fixture: TranscriptionRetryFixture,
        processing: TranscriptionRetryStartupProcessingRecorder,
        localIdentity: LocalAITranscriptionResumeIdentity,
        localDigest: String = "digest"
    ) throws -> TranscriptionRetryStartupInput {
        let cloud = try makeCloudState(
            historyID: UUID(),
            fixture: fixture,
            configuration: defaultCloudConfiguration(fixture: fixture)
        )
        return TranscriptionRetryStartupInput(
            reconciliation: CloudTranscriptionReconciliation(
                resumable: [record],
                waitingForRetry: [],
                invalid: []
            ),
            runtime: try requireCloudRuntime(cloud.execution),
            history: [item],
            audioDirectory: fixture.audioURL.deletingLastPathComponent(),
            cloudDependenciesFactory: {
                makeCloudDependencies(temporaryRoot: fixture.temporaryRoot)
            },
            makeProcessingBehavior: { item, completion in
                processing.behavior(item: item, completion: completion)
            },
            localAIExecution: makeLocalAIExecution(digest: localDigest),
            localAIResumeIdentity: localIdentity
        )
    }

    @MainActor
    private static func makeStartupInput(
        cloud: TranscriptionRetryCloudTestState,
        item: PipelineHistoryItem,
        fixture: TranscriptionRetryFixture,
        processing: TranscriptionRetryStartupProcessingRecorder,
        dependencyCount: TranscriptionRetryCounter = TranscriptionRetryCounter(),
        history: [PipelineHistoryItem]? = nil
    ) throws -> TranscriptionRetryStartupInput {
        TranscriptionRetryStartupInput(
            reconciliation: CloudTranscriptionReconciliation(
                resumable: [cloud.record],
                waitingForRetry: [],
                invalid: []
            ),
            runtime: try requireCloudRuntime(cloud.execution),
            history: history ?? [item],
            audioDirectory: fixture.audioURL.deletingLastPathComponent(),
            cloudDependenciesFactory: {
                dependencyCount.increment()
                return makeCloudDependencies(
                    temporaryRoot: fixture.temporaryRoot
                )
            },
            makeProcessingBehavior: { item, completion in
                processing.behavior(item: item, completion: completion)
            }
        )
    }

    private static func requireCloudRuntime(
        _ execution: TranscriptionExecutionSnapshot
    ) throws -> CloudTranscriptionExecutionSnapshot {
        guard case .cloud(let runtime, _) = execution else {
            throw TranscriptionRetryWorkflowTestFailure("expected cloud execution")
        }
        return runtime
    }

    private static func replacingAlgorithmVersion(
        in record: CloudTranscriptionJobRecord,
        with algorithmVersion: Int
    ) -> CloudTranscriptionJobRecord {
        let plan = CloudTranscriptionChunkPlan(
            algorithmVersion: algorithmVersion,
            encodedUploadCeilingBytes: record.plan.encodedUploadCeilingBytes,
            sourceFrameCount: record.plan.sourceFrameCount,
            chunks: record.plan.chunks,
            planID: record.plan.planID
        )
        return CloudTranscriptionJobRecord(
            schemaVersion: record.schemaVersion,
            historyID: record.historyID,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt,
            phase: record.phase,
            identity: record.identity,
            plan: plan,
            completedChunks: record.completedChunks,
            engineLanguageCode: record.engineLanguageCode,
            firstIncompleteChunkIndex: record.firstIncompleteChunkIndex,
            lastFailure: record.lastFailure,
            completionPolicy: record.completionPolicy
        )
    }

    @MainActor
    private static func drainTasks() async {
        for _ in 0..<5 {
            await Task.yield()
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }

    private static func defaultCloudConfiguration(
        fixture: TranscriptionRetryFixture
    ) -> TranscriptionRetryCloudTestConfiguration {
        TranscriptionRetryCloudTestConfiguration(
            baseURL: "https://provider.example/v1",
            apiKey: "runtime-only-key",
            model: "whisper-large-v3",
            language: "en",
            responseFormat: "verbose_json",
            encodedUploadCeilingBytes: fixture.ceiling,
            completionPolicy: CloudTranscriptionCompletionPolicy(
                postProcessingEnabled: true,
                outputLanguage: "en",
                pressEnterCommandEnabled: false
            )
        )
    }

    private static func makeCloudState(
        historyID: UUID,
        fixture: TranscriptionRetryFixture,
        configuration: TranscriptionRetryCloudTestConfiguration,
        completedPrefix: [String] = [],
        completeAllChunks: Bool = false
    ) throws -> TranscriptionRetryCloudTestState {
        let layout = try CanonicalPCM16WAV.validateFile(at: fixture.audioURL)
        let source = try CloudTranscriptionSourceIdentityBuilder.make(
            fileURL: fixture.audioURL,
            layout: layout,
            readBufferByteCount: 3
        )
        let multipart = CloudTranscriptionMultipartLayout(
            model: configuration.model,
            responseFormat: configuration.responseFormat,
            language: configuration.language,
            boundaryByteCount: 36
        )
        let plan = try CloudTranscriptionChunkPlanner().plan(
            fileURL: fixture.audioURL,
            source: source,
            wavLayout: layout,
            multipart: multipart,
            encodedUploadCeilingBytes:
                configuration.encodedUploadCeilingBytes
        )
        let runtime = try CloudTranscriptionExecutionSnapshot(
            baseURL: configuration.baseURL,
            apiKey: configuration.apiKey,
            model: configuration.model,
            language: configuration.language,
            responseFormat: configuration.responseFormat,
            encodedUploadCeilingBytes:
                configuration.encodedUploadCeilingBytes
        )
        let completedTexts = completeAllChunks
            ? plan.chunks.indices.map { "completed chunk \($0)" }
            : Array(completedPrefix.prefix(plan.chunks.count))
        let phase: CloudTranscriptionJobPhase = completeAllChunks
            ? .assembled
            : .transcribing
        let record = CloudTranscriptionJobRecord(
            schemaVersion: CloudTranscriptionJobRecord.currentSchemaVersion,
            historyID: historyID,
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 2_000),
            phase: phase,
            identity: CloudTranscriptionJobIdentity(
                providerID: runtime.providerID,
                model: runtime.model,
                language: runtime.language,
                responseFormat: runtime.responseFormat,
                source: source,
                planID: plan.planID
            ),
            plan: plan,
            completedChunks: completedTexts.enumerated().map {
                CloudTranscriptionCompletedChunk(
                    index: $0.offset,
                    normalizedRawText: $0.element
                )
            },
            firstIncompleteChunkIndex: completedTexts.count,
            lastFailure: nil,
            completionPolicy: configuration.completionPolicy
        )
        let completion = TranscriptionCompletionSnapshot(
            postProcessingEnabled:
                configuration.completionPolicy.postProcessingEnabled,
            outputLanguage: configuration.completionPolicy.outputLanguage,
            pressEnterCommandEnabled:
                configuration.completionPolicy.pressEnterCommandEnabled
        )
        return TranscriptionRetryCloudTestState(
            record: record,
            execution: .cloud(runtime, completion)
        )
    }

    private static func createStoredRecord(
        _ record: CloudTranscriptionJobRecord,
        in store: CloudTranscriptionJobStore
    ) throws {
        let session = store.beginSession(historyID: record.historyID)
        try store.create(record, session: session)
    }

    private static func makeLocalExecution() -> TranscriptionExecutionSnapshot {
        .local(
            LocalTranscriptionExecutionSnapshot(
                model: .find(id: "apple-speech"),
                localWhisperPath: nil,
                useLegacyMlxWhisper: false,
                language: .find(code: "en")
            ),
            TranscriptionCompletionSnapshot(
                postProcessingEnabled: true,
                outputLanguage: "en",
                pressEnterCommandEnabled: false
            )
        )
    }

    private static func localHistoryMetadata()
        -> TranscriptionRetryHistoryMetadata {
        TranscriptionRetryHistoryMetadata(
            customVocabulary: "captured vocabulary",
            customSystemPrompt: "captured system prompt",
            usedLocalTranscription: true,
            usedPostProcessing: true,
            transcriptionLanguageCode: "en",
            localTranscriptionModelID: "apple-speech",
            successDebugStatus: "Retried"
        )
    }

    private static func localFailureContext()
        -> TranscriptionRetryFailureContext {
        TranscriptionRetryFailureContext(
            fallbackCode: .localTranscriptionFailed,
            providerHost: nil,
            modelID: "apple-speech",
            localBackend: "apple-speech"
        )
    }

    private static func makeInstrumentedStore(
        fixture: TranscriptionRetryFixture,
        operationLog: TranscriptionRetryOperationLog,
        deletionError: TranscriptionRetryInjectedError? = nil
    ) -> CloudTranscriptionJobStore {
        let live = CloudTranscriptionAtomicWriteOperations.live
        let operations = CloudTranscriptionAtomicWriteOperations(
            openTemporary: live.openTemporary,
            writeAll: live.writeAll,
            syncFile: live.syncFile,
            closeFile: live.closeFile,
            replace: live.replace,
            syncDirectory: { url in
                operationLog.append("sidecar:delete")
                if let deletionError { throw deletionError }
                try live.syncDirectory(url)
            }
        )
        return CloudTranscriptionJobStore(
            jobsDirectory: fixture.jobsDirectory,
            temporaryRoot: fixture.temporaryRoot,
            now: { Date(timeIntervalSince1970: 2_000) },
            atomicWriteOperations: operations
        )
    }

    private static func failingDependencies<E: Error & Sendable>(
        _ error: E
    ) -> TranscriptionRetryWorkflowDependencies {
        TranscriptionRetryWorkflowDependencies(
            transcribe: { _, _, _, _ in throw error },
            makeAttemptToken: { UUID() }
        )
    }

    private static func makeMeetingSummary(
        actionCompleted: Bool
    ) -> MeetingSummaryEnvelope {
        MeetingSummaryEnvelope(
            schemaVersion: MeetingSummaryEnvelope.currentSchemaVersion,
            promptVersion: 1,
            generatedAt: Date(timeIntervalSince1970: 3_000),
            sourceFingerprint: String(repeating: "b", count: 64),
            modelID: "summary/model",
            backendKind: .cloud,
            content: MeetingSummaryContent(
                overview: MeetingSummaryEvidenceText(
                    text: "Existing overview",
                    sourceQuotes: []
                ),
                keyPoints: [],
                decisions: [],
                actionItems: [
                    MeetingSummaryActionItem(
                        id: UUID(uuidString: "00000000-0000-0000-0000-000000000318")!,
                        task: "Ship the workflow",
                        owner: "Team",
                        dueDate: nil,
                        sourceQuote: nil,
                        isCompleted: actionCompleted
                    )
                ],
                openQuestions: []
            )
        )
    }

    private static func immediateDependencies(
        text: String
    ) -> TranscriptionRetryWorkflowDependencies {
        TranscriptionRetryWorkflowDependencies(
            transcribe: { _, _, _, _ in
                transcriptionResult(text: text)
            },
            makeAttemptToken: { UUID() }
        )
    }

    private static func unusedDependencies(
        token: UUID
    ) -> TranscriptionRetryWorkflowDependencies {
        TranscriptionRetryWorkflowDependencies(
            transcribe: { _, _, _, _ in
                throw TranscriptionRetryWorkflowTestFailure(
                    "unexpected transcription"
                )
            },
            makeAttemptToken: { token }
        )
    }

    private static func transcriptionResult(text: String) -> TranscriptionResult {
        TranscriptionResult(
            text: text,
            spokenLanguage: SpokenLanguageResolution(
                languageCode: "en",
                source: .engineDetected
            )
        )
    }

    private static func processingBehaviorFromTranscription()
        -> TranscriptionRetryProcessingBehavior {
        TranscriptionRetryProcessingBehavior { transcription in
            processingResult(
                raw: transcription.text,
                final: transcription.text,
                spokenLanguage: transcription.spokenLanguage
            )
        }
    }

    private static func fixedProcessingBehavior(
        _ result: TranscriptionRetryProcessingResult
    ) -> TranscriptionRetryProcessingBehavior {
        TranscriptionRetryProcessingBehavior { _ in result }
    }

    private static func processingResult(
        raw: String = "new raw",
        final: String = "new final",
        disposition: TranscriptionRetryProcessingDisposition = .succeeded,
        outcome: AIProcessingOutcome = .succeeded,
        spokenLanguage: SpokenLanguageResolution = SpokenLanguageResolution(
            languageCode: "en",
            source: .engineDetected
        )
    ) -> TranscriptionRetryProcessingResult {
        TranscriptionRetryProcessingResult(
            rawTranscript: raw,
            finalTranscript: final,
            prompt: "captured prompt",
            postProcessingStatus: "Done",
            aiProcessingOutcome: outcome,
            spokenLanguage: spokenLanguage,
            disposition: disposition
        )
    }

    private static func makeFixture() throws -> TranscriptionRetryFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "retry-workflow-\(UUID().uuidString)",
                isDirectory: true
            )
        let audioDirectory = root.appendingPathComponent("audio", isDirectory: true)
        let jobsDirectory = root.appendingPathComponent("jobs", isDirectory: true)
        let temporaryRoot = root.appendingPathComponent("temporary", isDirectory: true)
        try FileManager.default.createDirectory(
            at: audioDirectory,
            withIntermediateDirectories: true
        )
        let audioURL = audioDirectory.appendingPathComponent("recording.wav")
        try writeCanonicalWAV(
            samples: [1, 1, 2, 2, 3, 3],
            to: audioURL
        )
        let multipart = CloudTranscriptionMultipartLayout(
            model: "whisper-large-v3",
            responseFormat: "verbose_json",
            language: "en",
            boundaryByteCount: 36
        )
        let ceiling = try multipart.encodedByteCount(
            audioDataByteCount: CanonicalPCM16WAV.headerByteCount + 4,
            fileName: CloudTranscriptionChunkPlanner.uploadFileName,
            contentType: "audio/wav"
        )
        return TranscriptionRetryFixture(
            root: root,
            audioURL: audioURL,
            jobsDirectory: jobsDirectory,
            temporaryRoot: temporaryRoot,
            ceiling: ceiling,
            jobStore: CloudTranscriptionJobStore(
                jobsDirectory: jobsDirectory,
                temporaryRoot: temporaryRoot,
                now: { Date(timeIntervalSince1970: 2_000) }
            )
        )
    }

    private static func writeCanonicalWAV(
        samples: [Int16],
        to url: URL
    ) throws {
        var data = CanonicalPCM16WAV.header(
            dataByteCount: UInt32(samples.count * 2)
        )
        for sample in samples {
            let bits = UInt16(bitPattern: sample)
            data.append(UInt8(bits & 0xff))
            data.append(UInt8((bits >> 8) & 0xff))
        }
        try data.write(to: url, options: .atomic)
    }

    private static func makeHistoryItem(
        id: UUID = UUID(),
        timestamp: Date = Date(timeIntervalSince1970: 1_000),
        audioFileName: String = "recording.wav",
        rawTranscript: String = "old raw",
        postProcessedTranscript: String = "old final",
        contextSummary: String = "stored context",
        aiProcessingOutcome: String = "succeeded",
        transcriptFileName: String? = nil
    ) -> PipelineHistoryItem {
        PipelineHistoryItem(
            id: id,
            timestamp: timestamp,
            rawTranscript: rawTranscript,
            postProcessedTranscript: postProcessedTranscript,
            postProcessingPrompt: "old prompt",
            contextSummary: contextSummary,
            contextScreenshotDataURL: nil,
            contextScreenshotStatus: "No screenshot",
            postProcessingStatus: "Done",
            aiProcessingOutcome: aiProcessingOutcome,
            debugStatus: "old debug",
            customVocabulary: "stored vocabulary",
            customSystemPrompt: "stored system prompt",
            audioFileName: audioFileName,
            usedLocalTranscription: false,
            usedContextCapture: true,
            usedPostProcessing: true,
            transcriptionLanguageCode: "en",
            localTranscriptionModelID: "mlx-community/whisper-large-v3-turbo",
            transcriptFileName: transcriptFileName,
            customTitle: "Current title"
        )
    }

    private static func makeCloudExecution(
        model: String = "whisper-large-v3",
        completion: TranscriptionCompletionSnapshot = TranscriptionCompletionSnapshot(
            postProcessingEnabled: true,
            outputLanguage: "en",
            pressEnterCommandEnabled: false
        )
    ) throws -> TranscriptionExecutionSnapshot {
        .cloud(
            try CloudTranscriptionExecutionSnapshot(
                baseURL: "https://provider.example/v1",
                apiKey: "runtime-only-key",
                model: model,
                language: "en",
                encodedUploadCeilingBytes: 20_000_000
            ),
            completion
        )
    }

    private static func makeCloudDependencies(
        temporaryRoot: URL
    ) -> CloudTranscriptionDependencies {
        CloudTranscriptionDependencies(
            encodedUploadCeilingBytes: 20_000_000,
            upload: { _, _ in
                throw TranscriptionRetryWorkflowTestFailure("unexpected upload")
            },
            checkpointStore: InMemoryCloudTranscriptionCheckpointStore(),
            progress: { _ in },
            temporaryRoot: temporaryRoot,
            sleep: { _ in }
        )
    }

    private static func makeRequest(
        item: PipelineHistoryItem,
        fixture: TranscriptionRetryFixture,
        execution: TranscriptionExecutionSnapshot? = nil,
        cloudDependencies: CloudTranscriptionDependencies? = nil,
        processing: TranscriptionRetryProcessingBehavior? = nil,
        historyMetadata: TranscriptionRetryHistoryMetadata =
            TranscriptionRetryHistoryMetadata(
                customVocabulary: "captured vocabulary",
                customSystemPrompt: "captured system prompt",
                usedLocalTranscription: false,
                usedPostProcessing: true,
                transcriptionLanguageCode: "en",
                localTranscriptionModelID: "captured/local",
                successDebugStatus: "Retried"
            ),
        failureContext: TranscriptionRetryFailureContext =
            TranscriptionRetryFailureContext(
                fallbackCode: .providerConfigurationInvalid,
                providerHost: "provider.example",
                modelID: "whisper-large-v3",
                localBackend: nil
            )
    ) throws -> TranscriptionRetryWorkflowRequest {
        guard let audioFileName = item.audioFileName else {
            throw TranscriptionRetryWorkflowTestFailure("missing audio filename")
        }
        return TranscriptionRetryWorkflowRequest(
            origin: .manual,
            deliveryPolicy: .interactive,
            initialItem: item,
            sourceIdentity: TranscriptionRetrySourceIdentity(
                noteID: item.id,
                noteTimestamp: item.timestamp,
                audioFileName: audioFileName
            ),
            audioURL: fixture.audioURL,
            execution: try execution ?? makeCloudExecution(),
            cloudDependencies: cloudDependencies
                ?? makeCloudDependencies(temporaryRoot: fixture.temporaryRoot),
            processing: processing ?? fixedProcessingBehavior(processingResult()),
            historyMetadata: historyMetadata,
            failureContext: failureContext
        )
    }

    @MainActor
    private static func waitUntil(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw TranscriptionRetryWorkflowTestFailure("timed out waiting for condition")
    }

    private static func require<T>(_ value: T?, _ label: String) throws -> T {
        guard let value else { throw TranscriptionRetryWorkflowTestFailure(label) }
        return value
    }

    private static func requireSuccessCompletion(
        _ outcome: TranscriptionRetryWorkflowOutcome?
    ) throws -> TranscriptionRetryCompletion {
        guard case .succeeded(let completion)? = outcome else {
            throw TranscriptionRetryWorkflowTestFailure("success completion")
        }
        return completion
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ label: String
    ) throws {
        guard condition() else {
            throw TranscriptionRetryWorkflowTestFailure(label)
        }
    }

    private static func expectEqual<T: Equatable>(
        _ actual: T,
        _ expected: T,
        _ label: String
    ) throws {
        guard actual == expected else {
            throw TranscriptionRetryWorkflowTestFailure(
                "\(label): expected \(expected), got \(actual)"
            )
        }
    }
}

@MainActor
private final class TranscriptionRetryHistoryRecorder {
    var currentItem: PipelineHistoryItem?
    var persistedItems: [PipelineHistoryItem] = []
    var operations: [String] = []
    var lookupError: Error?
    var persistError: Error?
    var durability: PipelineHistoryDurability = .durable

    private let operationLog: TranscriptionRetryOperationLog?

    init(
        item: PipelineHistoryItem?,
        operationLog: TranscriptionRetryOperationLog? = nil
    ) {
        currentItem = item
        self.operationLog = operationLog
    }

    func access() -> TranscriptionRetryHistoryAccess {
        TranscriptionRetryHistoryAccess(
            durability: { [weak self] in
                self?.durability ?? .inMemory
            },
            item: { [weak self] id in
                guard let self else { return nil }
                if let lookupError { throw lookupError }
                operations.append("lookup")
                operationLog?.append("history:lookup")
                guard currentItem?.id == id else { return nil }
                return currentItem
            },
            persist: { [weak self] item, requiresDurableStore in
                guard let self else { return }
                guard requiresDurableStore else {
                    throw TranscriptionRetryWorkflowTestFailure(
                        "durable history required"
                    )
                }
                if let persistError { throw persistError }
                operations.append("persist")
                operationLog?.append("history:persist")
                persistedItems.append(item)
                currentItem = item
            }
        )
    }
}

private final class TranscriptionRetryAssetRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var savedNames: [String] = []
    private var deletedNames: [String] = []
    private let operationLog: TranscriptionRetryOperationLog?
    var saveError: Error?
    var deleteError: Error?

    init(operationLog: TranscriptionRetryOperationLog? = nil) {
        self.operationLog = operationLog
    }

    func access(fileName: String = "created.txt")
        -> TranscriptionRetryAssetAccess {
        TranscriptionRetryAssetAccess(
            saveTranscript: { [self] _, _ in
                lock.lock()
                defer { lock.unlock() }
                if let saveError { throw saveError }
                savedNames.append(fileName)
                operationLog?.append("asset:save")
                return fileName
            },
            deleteTranscript: { [self] fileName in
                lock.lock()
                defer { lock.unlock() }
                if let deleteError { throw deleteError }
                deletedNames.append(fileName)
                operationLog?.append("asset:delete")
            }
        )
    }

    func saved() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return savedNames
    }

    func deleted() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return deletedNames
    }
}

@MainActor
private final class TranscriptionRetryStartupProcessingRecorder {
    private let result: TranscriptionRetryProcessingResult
    private(set) var items: [PipelineHistoryItem] = []
    private(set) var completions: [TranscriptionCompletionSnapshot] = []

    init(result: TranscriptionRetryProcessingResult) {
        self.result = result
    }

    func behavior(
        item: PipelineHistoryItem,
        completion: TranscriptionCompletionSnapshot
    ) -> TranscriptionRetryProcessingBehavior {
        items.append(item)
        completions.append(completion)
        return TranscriptionRetryProcessingBehavior { _ in self.result }
    }
}

private final class TranscriptionRetryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        storage += 1
    }

    func value() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

@MainActor
private final class TranscriptionRetryEventRecorder {
    private(set) var states: [TranscriptionRetryWorkflowState] = []
    private(set) var persistedEvents: [(
        item: PipelineHistoryItem,
        effects: TranscriptionRetryPersistedEffects
    )] = []
    private(set) var outcomes: [TranscriptionRetryWorkflowOutcome] = []

    private let operationLog: TranscriptionRetryOperationLog?

    init(operationLog: TranscriptionRetryOperationLog? = nil) {
        self.operationLog = operationLog
    }

    func record(_ event: TranscriptionRetryWorkflowEvent) {
        switch event {
        case .stateChanged(let state):
            states.append(state)
            operationLog?.append(
                state.retryingNoteIDs.isEmpty
                    ? "state:finished"
                    : "state:started"
            )
        case .itemPersisted(let item, let effects):
            persistedEvents.append((item, effects))
            operationLog?.append("event:itemPersisted")
        case .completed(_, let outcome):
            outcomes.append(outcome)
            operationLog?.append("event:completed")
        }
    }
}

private final class TranscriptionRetryOperationLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ value: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(value)
    }

    func values() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private actor TranscriptionRetryInvocationRecorder {
    struct Snapshot: Equatable, Sendable {
        let model: String
        let outputLanguage: String
        let pressEnterCommandEnabled: Bool
        let temporaryRoot: URL
    }

    private var snapshots: [Snapshot] = []

    func record(
        execution: TranscriptionExecutionSnapshot,
        dependencies: CloudTranscriptionDependencies
    ) {
        let model: String
        switch execution {
        case .cloud(let cloud, _):
            model = cloud.model
        case .local(let local, _):
            model = local.model.id
        }
        snapshots.append(
            Snapshot(
                model: model,
                outputLanguage: execution.completion.outputLanguage,
                pressEnterCommandEnabled:
                    execution.completion.pressEnterCommandEnabled,
                temporaryRoot: dependencies.temporaryRoot
            )
        )
    }

    func snapshot() -> Snapshot? {
        snapshots.last
    }

    func count() -> Int {
        snapshots.count
    }
}

private actor TranscriptionRetryCloudContextRecorder {
    struct Snapshot: Sendable {
        let oldRecordPresentBeforePreparation: Bool
        let completedPrefix: [String]
        let preparedRecord: CloudTranscriptionJobRecord?
    }

    private var latest: Snapshot?

    func record(
        oldRecordPresentBeforePreparation: Bool,
        completedPrefix: [String],
        preparedRecord: CloudTranscriptionJobRecord?
    ) {
        latest = Snapshot(
            oldRecordPresentBeforePreparation:
                oldRecordPresentBeforePreparation,
            completedPrefix: completedPrefix,
            preparedRecord: preparedRecord
        )
    }

    func snapshot() -> Snapshot? {
        latest
    }
}

private actor TranscriptionRetryExecutionRecorder {
    private var recorded: [String] = []

    func record(execution: TranscriptionExecutionSnapshot, hasContext: Bool) {
        switch execution {
        case .cloud:
            recorded.append("cloud context:\(hasContext)")
        case .local(let local, _):
            let provider = local.localAIExecution?.providerID ?? "local"
            recorded.append("\(provider) context:\(hasContext)")
        }
    }

    func summary() -> [String] {
        recorded
    }
}

private actor TranscriptionRetryLocalContextRecorder {
    private var recordedContextWasNil = false

    func record(contextWasNil: Bool) {
        recordedContextWasNil = contextWasNil
    }

    func contextWasNil() -> Bool {
        recordedContextWasNil
    }
}

private struct TranscriptionRetryCloudTestConfiguration: Sendable {
    var baseURL: String
    var apiKey: String
    var model: String
    var language: String?
    var responseFormat: String
    var encodedUploadCeilingBytes: UInt64
    var completionPolicy: CloudTranscriptionCompletionPolicy
}

private struct TranscriptionRetryCloudTestState: Sendable {
    let record: CloudTranscriptionJobRecord
    let execution: TranscriptionExecutionSnapshot
}

private enum TranscriptionRetryCloudMismatch: CaseIterable, Equatable, Sendable {
    case provider
    case model
    case language
    case responseFormat
    case uploadCeiling
    case completionPolicy

    var label: String {
        switch self {
        case .provider: return "provider"
        case .model: return "model"
        case .language: return "language"
        case .responseFormat: return "response format"
        case .uploadCeiling: return "upload ceiling"
        case .completionPolicy: return "completion policy"
        }
    }

    func applying(
        to configuration: TranscriptionRetryCloudTestConfiguration,
        fixture: TranscriptionRetryFixture
    ) -> TranscriptionRetryCloudTestConfiguration {
        var updated = configuration
        switch self {
        case .provider:
            updated.baseURL = "https://replacement.example/v1"
        case .model:
            updated.model = "whisper-1"
        case .language:
            updated.language = "ko"
        case .responseFormat:
            updated.responseFormat = "json"
        case .uploadCeiling:
            updated.encodedUploadCeilingBytes = fixture.ceiling + 1_000
        case .completionPolicy:
            updated.completionPolicy = CloudTranscriptionCompletionPolicy(
                postProcessingEnabled: false,
                outputLanguage: "ko",
                pressEnterCommandEnabled: true
            )
        }
        return updated
    }
}

private actor TranscriptionRetryControlledTranscriber {
    private var continuation:
        CheckedContinuation<TranscriptionResult, Error>?
    private var started = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []

    func run(
        context: CloudTranscriptionExecutionContext?,
        emitsProgress: Bool = true
    ) async throws -> TranscriptionResult {
        if emitsProgress {
            context?.progress(.uploading(index: 1, total: 3, attempt: 2))
        }
        started = true
        let waiters = startedWaiters
        startedWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startedWaiters.append(continuation)
        }
    }

    func succeed(_ result: TranscriptionResult) {
        continuation?.resume(returning: result)
        continuation = nil
    }

    func fail(_ error: any Error & Sendable) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

private actor TranscriptionRetryMultiControlledTranscriber {
    private struct Call {
        let context: CloudTranscriptionExecutionContext?
        let continuation: CheckedContinuation<TranscriptionResult, Error>
    }

    private var calls: [Int: Call] = [:]
    private var nextCallIndex = 0
    private var callCountWaiters: [(
        count: Int,
        continuation: CheckedContinuation<Void, Never>
    )] = []

    func run(
        context: CloudTranscriptionExecutionContext?
    ) async throws -> TranscriptionResult {
        let callIndex = nextCallIndex
        nextCallIndex += 1
        return try await withCheckedThrowingContinuation { continuation in
            calls[callIndex] = Call(
                context: context,
                continuation: continuation
            )
            resumeSatisfiedWaiters()
        }
    }

    func waitUntilCallCount(_ count: Int) async {
        if calls.count >= count { return }
        await withCheckedContinuation { continuation in
            callCountWaiters.append((count, continuation))
        }
    }

    func emitProgress(call: Int, progress: CloudTranscriptionProgress) {
        calls[call]?.context?.progress(progress)
    }

    func succeed(call: Int, result: TranscriptionResult) {
        calls.removeValue(forKey: call)?.continuation.resume(returning: result)
    }

    func fail(call: Int, error: any Error & Sendable) {
        calls.removeValue(forKey: call)?.continuation.resume(throwing: error)
    }

    private func resumeSatisfiedWaiters() {
        var remaining: [(
            count: Int,
            continuation: CheckedContinuation<Void, Never>
        )] = []
        for waiter in callCountWaiters {
            if calls.count >= waiter.count {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        callCountWaiters = remaining
    }
}

private final class TranscriptionRetryTokenSource: @unchecked Sendable {
    private let lock = NSLock()
    private var counter: UInt64 = 0

    func next() -> UUID {
        lock.lock()
        defer { lock.unlock() }
        counter &+= 1
        let suffix = String(format: "%012llx", counter)
        return UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")!
    }
}

private enum TranscriptionRetrySourceChange: Equatable, Sendable {
    case audioFileName
    case timestamp

    func changedItem(from item: PipelineHistoryItem) -> PipelineHistoryItem {
        PipelineHistoryItem(
            intent: item.intent,
            selectedText: item.selectedText,
            capturedSelection: item.capturedSelection,
            id: item.id,
            timestamp: self == .timestamp
                ? item.timestamp.addingTimeInterval(1)
                : item.timestamp,
            recordingStartedAt: item.recordingStartedAt,
            recordingEndedAt: item.recordingEndedAt,
            calendarMatch: item.calendarMatch,
            rawTranscript: item.rawTranscript,
            postProcessedTranscript: item.postProcessedTranscript,
            postProcessingPrompt: item.postProcessingPrompt,
            systemPrompt: item.systemPrompt,
            contextSummary: item.contextSummary,
            contextSystemPrompt: item.contextSystemPrompt,
            contextPrompt: item.contextPrompt,
            contextScreenshotDataURL: item.contextScreenshotDataURL,
            contextScreenshotStatus: item.contextScreenshotStatus,
            postProcessingStatus: item.postProcessingStatus,
            aiProcessingOutcome: item.aiProcessingOutcome,
            debugStatus: item.debugStatus,
            customVocabulary: item.customVocabulary,
            customSystemPrompt: item.customSystemPrompt,
            audioFileName: self == .audioFileName
                ? "replacement.wav"
                : item.audioFileName,
            usedLocalTranscription: item.usedLocalTranscription,
            usedContextCapture: item.usedContextCapture,
            usedPostProcessing: item.usedPostProcessing,
            transcriptionLanguageCode: item.transcriptionLanguageCode,
            spokenLanguageCode: item.spokenLanguageCode,
            spokenLanguageResolution: item.spokenLanguageResolution,
            meetingSummaryAttempt: item.meetingSummaryAttempt,
            localTranscriptionModelID: item.localTranscriptionModelID,
            transcriptFileName: item.transcriptFileName,
            contextAppName: item.contextAppName,
            contextBundleIdentifier: item.contextBundleIdentifier,
            contextWindowTitle: item.contextWindowTitle,
            customTitle: item.customTitle,
            meetingSummaryJSON: item.meetingSummaryJSON
        )
    }
}

private struct TranscriptionRetryFixture: Sendable {
    let root: URL
    let audioURL: URL
    let jobsDirectory: URL
    let temporaryRoot: URL
    let ceiling: UInt64
    let jobStore: CloudTranscriptionJobStore

    func runtime(
        history: TranscriptionRetryHistoryAccess,
        assets: TranscriptionRetryAssetAccess,
        jobStore storeOverride: CloudTranscriptionJobStore? = nil,
        cancelExisting: @escaping @MainActor @Sendable (UUID) -> Void = { _ in }
    ) -> TranscriptionRetryWorkflowRuntime {
        TranscriptionRetryWorkflowRuntime(
            history: history,
            assets: assets,
            cloud: TranscriptionRetryCloudAccess(
                jobStore: storeOverride ?? jobStore,
                cancelExistingExecution: cancelExisting
            )
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private enum TranscriptionRetryInjectedError: Error, Sendable {
    case provider
    case assetSave
    case historySave
    case historyRead
    case sidecarDelete
}

private struct TranscriptionRetryWorkflowTestFailure:
    Error,
    CustomStringConvertible,
    Sendable {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
