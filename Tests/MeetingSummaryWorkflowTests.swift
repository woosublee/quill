import Foundation

#if !QUILL_GROUPED_TEST_RUNNER
@main
#endif
struct MeetingSummaryWorkflowTests {
    static func main() async throws {
        try await testStateAndInvalidationCommands()
        try await testVerifiedSuccessPersistsBeforeEventAndPreservesCompletion()
        try await testUnverifiedSuccessPersistsWarningAndAttempt()
        try await testCandidateSuccessSavesNothingUntilChosen()
        try await testExplicitLanguageOverridesSpokenLanguage()
        try await testEngineDetectedLanguageRequiresNoPreliminaryWrite()
        try await testTranscriptInferredLanguagePersistsBeforeGeneration()
        try await testUnavailableLanguageReturnsExistingIssue()
        try await testGenerationFailurePersistsAttemptWithoutReplacingSummary()
        try await testInferredLanguagePersistenceFailureIsTyped()
        try await testFailedAttemptPersistenceFailureIsTyped()
        try await testSuccessfulSummaryPersistenceFailureIsTyped()
        try await testNonDurableHistoryRejectsBeforeGeneration()
        try await testStaleSuccessCompletionsAreRejected()
        try await testStaleFailureCompletionsAreRejected()
        try await testStaleGenerationCannotClearNewerGenerationState()
        try await testMissingDurableStartRejectsCompletionAfterGeneratorRuns()
        print("MeetingSummaryWorkflowTests passed")
    }

    @MainActor
    private static func testStateAndInvalidationCommands() async throws {
        let workflow = MeetingSummaryWorkflow(
            dependencies: .init(
                makeGenerator: { _ in
                    MeetingSummaryWorkflowGeneratorStub { _ in
                        throw MeetingSummaryError.invalidInput
                    }
                },
                now: { Date(timeIntervalSince1970: 2_000) }
            )
        )
        let noteID = UUID()
        var states: [MeetingSummaryWorkflowState] = []
        workflow.onEvent = { event in
            if case .stateChanged(let state) = event {
                states.append(state)
            }
        }

        workflow.invalidate(noteID: noteID)
        workflow.forget(noteID: noteID)
        workflow.forgetAll()

        try expect(
            workflow.state.generatingNoteIDs.isEmpty,
            "no generation is active"
        )
        try expect(
            workflow.state.pendingRevealNoteIDs.isEmpty,
            "no reveal is pending"
        )
        try expect(
            !states.isEmpty,
            "state commands emit complete snapshots"
        )
        try expect(
            !workflow.consumePendingReveal(noteID: noteID),
            "missing reveal is not consumed"
        )
    }

    @MainActor
    private static func
        testVerifiedSuccessPersistsBeforeEventAndPreservesCompletion() async throws
    {
        let actionID = UUID()
        let initial = makeWorkflowItem().withMeetingSummary(
            makeWorkflowEnvelope(actionID: actionID, completed: true)
        )
        let history = MeetingSummaryWorkflowHistoryRecorder(item: initial)
        let eventRecorder = MeetingSummaryWorkflowEventRecorder(history: history)
        let workflow = MeetingSummaryWorkflow(
            dependencies: .init(
                makeGenerator: { _ in
                    MeetingSummaryWorkflowGeneratorStub { _ in
                        makeWorkflowGenerationResult(actionID: actionID)
                    }
                },
                now: { Date(timeIntervalSince1970: 2_000) }
            )
        )
        workflow.onEvent = { eventRecorder.record($0) }

        let outcome = await workflow.generate(
            request: makeWorkflowRequest(item: initial),
            history: history.access
        )

        try expect(isVerifiedSuccess(outcome), "verified success is typed")
        try expect(
            history.storedItem?.meetingSummary?
                .content.actionItems.first?.isCompleted == true,
            "successful generation preserves action completion"
        )
        try expect(
            history.storedItem?.meetingSummaryAttempt?.outcome == .succeeded,
            "successful generation persists a succeeded attempt"
        )
        try expect(
            eventRecorder.itemEventsObservedAfterPersistence,
            "item events follow durable persistence"
        )
        try expect(
            workflow.consumePendingReveal(noteID: initial.id),
            "success creates pending reveal"
        )
        try expect(
            !workflow.consumePendingReveal(noteID: initial.id),
            "pending reveal is consumed once"
        )
    }

    /// #262: a summary made to compare with an edited one waits as a
    /// candidate; nothing is saved, and invalidating the note drops it.
    @MainActor
    private static func testCandidateSuccessSavesNothingUntilChosen() async throws {
        let initial = makeWorkflowItem()
        let history = MeetingSummaryWorkflowHistoryRecorder(item: initial)
        let eventRecorder = MeetingSummaryWorkflowEventRecorder(history: history)
        let workflow = MeetingSummaryWorkflow(
            dependencies: .init(
                makeGenerator: { _ in
                    MeetingSummaryWorkflowGeneratorStub { _ in
                        makeWorkflowGenerationResult()
                    }
                },
                now: { Date(timeIntervalSince1970: 2_000) }
            )
        )
        workflow.onEvent = { eventRecorder.record($0) }
        var request = makeWorkflowRequest(item: initial)
        request.deliversCandidate = true

        let outcome = await workflow.generate(request: request, history: history.access)

        try expect(isVerifiedSuccess(outcome), "candidate success is typed")
        try expect(history.storedItem?.meetingSummary == nil, "the candidate summary is not saved")
        try expect(history.storedItem?.meetingSummaryAttempt == nil, "the candidate attempt is not saved")
        try expect(eventRecorder.persistedItems.isEmpty, "no item is persisted")
        let candidate = workflow.state.candidates[initial.id]
        try expect(candidate?.attempt.outcome == .succeeded, "the candidate waits with its attempt")
        try expect(candidate?.envelope.content.overview.text.isEmpty == false, "the candidate has content")
        try expect(!workflow.state.generatingNoteIDs.contains(initial.id), "generation finished")
        try expect(!workflow.state.pendingRevealNoteIDs.contains(initial.id), "no reveal for a candidate")

        workflow.invalidate(noteID: initial.id)
        try expect(workflow.state.candidates[initial.id] == nil, "invalidating the note drops its candidate")
    }

    @MainActor
    private static func testUnverifiedSuccessPersistsWarningAndAttempt() async throws {
        let initial = makeWorkflowItem()
        let history = MeetingSummaryWorkflowHistoryRecorder(item: initial)
        let eventRecorder = MeetingSummaryWorkflowEventRecorder(history: history)
        let workflow = MeetingSummaryWorkflow(
            dependencies: .init(
                makeGenerator: { _ in
                    MeetingSummaryWorkflowGeneratorStub { _ in
                        makeWorkflowGenerationResult(
                            evidenceVerification: .unverified
                        )
                    }
                },
                now: { Date(timeIntervalSince1970: 2_000) }
            )
        )
        workflow.onEvent = { eventRecorder.record($0) }

        let outcome = await workflow.generate(
            request: makeWorkflowRequest(item: initial),
            history: history.access
        )

        try expect(
            isUnverifiedSuccess(outcome),
            "unverified success is typed"
        )
        try expect(
            history.storedItem?.meetingSummary?
                .effectiveEvidenceVerification == .unverified,
            "unverified evidence state is persisted"
        )
        try expect(
            history.storedItem?.meetingSummaryAttempt?.outcome == .succeeded,
            "unverified success persists a succeeded attempt"
        )
        try expect(
            eventRecorder.persistedItems.count == 1,
            "unverified success emits one persisted item"
        )
    }

    @MainActor
    private static func testExplicitLanguageOverridesSpokenLanguage() async throws {
        let initial = makeWorkflowItem(
            spokenLanguageCode: "ko",
            spokenLanguageResolution: .engineDetected
        )
        let history = MeetingSummaryWorkflowHistoryRecorder(item: initial)
        let sourceRecorder = MeetingSummaryWorkflowSourceRecorder()
        let workflow = MeetingSummaryWorkflow(
            dependencies: .init(
                makeGenerator: { _ in
                    MeetingSummaryWorkflowGeneratorStub { source in
                        await sourceRecorder.record(source)
                        return makeWorkflowGenerationResult()
                    }
                },
                now: { Date(timeIntervalSince1970: 2_000) }
            )
        )

        let outcome = await workflow.generate(
            request: makeWorkflowRequest(
                item: initial,
                requestedOutputLanguage: "English"
            ),
            history: history.access
        )
        let source = await sourceRecorder.latest()

        try expect(isVerifiedSuccess(outcome), "explicit language succeeds")
        try expect(
            source?.languageContext.appliedLanguageCode == "en",
            "explicit output language overrides spoken language"
        )
        try expect(
            source?.languageContext.resolutionSource == .configured,
            "explicit output language records configured resolution"
        )
        try expect(
            history.persistedItems.count == 1,
            "explicit language requires only the Summary write"
        )
    }

    @MainActor
    private static func
        testEngineDetectedLanguageRequiresNoPreliminaryWrite() async throws
    {
        let initial = makeWorkflowItem(
            spokenLanguageCode: "ko",
            spokenLanguageResolution: .engineDetected
        )
        let history = MeetingSummaryWorkflowHistoryRecorder(item: initial)
        let sourceRecorder = MeetingSummaryWorkflowSourceRecorder()
        let workflow = MeetingSummaryWorkflow(
            dependencies: .init(
                makeGenerator: { _ in
                    MeetingSummaryWorkflowGeneratorStub { source in
                        await sourceRecorder.record(source)
                        return makeWorkflowGenerationResult()
                    }
                },
                now: { Date(timeIntervalSince1970: 2_000) }
            )
        )

        let outcome = await workflow.generate(
            request: makeWorkflowRequest(
                item: initial,
                requestedOutputLanguage: ""
            ),
            history: history.access
        )
        let source = await sourceRecorder.latest()

        try expect(isVerifiedSuccess(outcome), "detected language succeeds")
        try expect(
            source?.languageContext.appliedLanguageCode == "ko",
            "engine-detected language is applied"
        )
        try expect(
            source?.languageContext.resolutionSource == .engineDetected,
            "engine-detected source is preserved"
        )
        try expect(
            history.persistedItems.count == 1,
            "engine-detected language requires no preliminary write"
        )
    }

    @MainActor
    private static func
        testTranscriptInferredLanguagePersistsBeforeGeneration() async throws
    {
        let transcript = "회의에서 다음 주 화요일에 출시하기로 결정했습니다."
        let initial = makeWorkflowItem(
            transcript: transcript,
            spokenLanguageCode: nil,
            spokenLanguageResolution: nil
        )
        let history = MeetingSummaryWorkflowHistoryRecorder(item: initial)
        let eventRecorder = MeetingSummaryWorkflowEventRecorder(history: history)
        let sourceRecorder = MeetingSummaryWorkflowSourceRecorder()
        let workflow = MeetingSummaryWorkflow(
            dependencies: .init(
                makeGenerator: { _ in
                    MeetingSummaryWorkflowGeneratorStub { source in
                        await sourceRecorder.record(source)
                        return makeWorkflowGenerationResult()
                    }
                },
                now: { Date(timeIntervalSince1970: 2_000) }
            )
        )
        workflow.onEvent = { eventRecorder.record($0) }

        let outcome = await workflow.generate(
            request: makeWorkflowRequest(
                item: initial,
                requestedOutputLanguage: ""
            ),
            history: history.access
        )
        let source = await sourceRecorder.latest()

        try expect(isVerifiedSuccess(outcome), "inferred language succeeds")
        try expect(
            history.persistedItems.first?.spokenLanguage
                == SpokenLanguageResolution(
                    languageCode: "ko",
                    source: .transcriptInferred
                ),
            "inferred Korean is durably saved first"
        )
        try expect(
            source?.languageContext.appliedLanguageCode == "ko",
            "generator receives the inferred Korean language"
        )
        try expect(
            source?.languageContext.resolutionSource == .transcriptInferred,
            "generator receives transcript-inferred resolution"
        )
        try expect(
            history.operations == ["persist-1", "persist-2"],
            "language metadata is saved before the Summary"
        )
        try expect(
            eventRecorder.persistedItems.count == 2,
            "each durable write emits one item event"
        )
    }

    @MainActor
    private static func testUnavailableLanguageReturnsExistingIssue() async throws {
        let initial = makeWorkflowItem(
            transcript: "",
            spokenLanguageCode: nil,
            spokenLanguageResolution: nil
        )
        let history = MeetingSummaryWorkflowHistoryRecorder(item: initial)
        let workflow = MeetingSummaryWorkflow(
            dependencies: .init(
                makeGenerator: { _ in
                    MeetingSummaryWorkflowGeneratorStub { _ in
                        makeWorkflowGenerationResult()
                    }
                },
                now: { Date(timeIntervalSince1970: 2_000) }
            )
        )

        let outcome = await workflow.generate(
            request: makeWorkflowRequest(
                item: initial,
                requestedOutputLanguage: ""
            ),
            history: history.access
        )

        guard case .generationFailed(let error) = outcome,
              let issue = error as? QuillUserIssueError else {
            throw MeetingSummaryWorkflowTestFailure(
                description: "language failure preserves its user issue"
            )
        }
        try expect(
            issue.record.code == .meetingSummaryLanguageUnavailable,
            "unavailable language uses the existing issue code"
        )
    }

    @MainActor
    private static func
        testGenerationFailurePersistsAttemptWithoutReplacingSummary() async throws
    {
        let actionID = UUID()
        let existing = makeWorkflowEnvelope(actionID: actionID, completed: true)
        let initial = makeWorkflowItem().withMeetingSummary(existing)
        let history = MeetingSummaryWorkflowHistoryRecorder(item: initial)
        let failure = MeetingSummaryError.outputRejected(
            .languageMismatch,
            modelID: "fallback/model"
        )
        let workflow = MeetingSummaryWorkflow(
            dependencies: .init(
                makeGenerator: { _ in
                    MeetingSummaryWorkflowGeneratorStub { _ in
                        throw failure
                    }
                },
                now: { Date(timeIntervalSince1970: 2_000) }
            )
        )

        let outcome = await workflow.generate(
            request: makeWorkflowRequest(item: initial),
            history: history.access
        )

        try expect(
            isGenerationFailure(outcome, matching: failure),
            "generation failure is typed"
        )
        try expect(
            history.storedItem?.meetingSummary == existing,
            "failure preserves the existing Summary"
        )
        try expect(
            history.storedItem?.meetingSummary?
                .content.actionItems.first?.isCompleted == true,
            "failure preserves action completion"
        )
        try expect(
            history.storedItem?.meetingSummaryAttempt?.outcome == .failed,
            "failure persists a failed attempt"
        )
        try expect(
            history.storedItem?.meetingSummaryAttempt?.modelID
                == "fallback/model",
            "failure records the effective model"
        )
        try expect(
            history.storedItem?.meetingSummaryAttempt?.providerHost
                == "api.example.com",
            "failure records the captured provider host"
        )
    }

    @MainActor
    private static func testInferredLanguagePersistenceFailureIsTyped() async throws {
        let initial = makeWorkflowItem(
            transcript: "회의에서 다음 주 화요일에 출시하기로 결정했습니다.",
            spokenLanguageCode: nil,
            spokenLanguageResolution: nil
        )
        let history = MeetingSummaryWorkflowHistoryRecorder(item: initial)
        history.failingPersistCalls = [1]
        let eventRecorder = MeetingSummaryWorkflowEventRecorder(history: history)
        let workflow = MeetingSummaryWorkflow(
            dependencies: .init(
                makeGenerator: { _ in
                    MeetingSummaryWorkflowGeneratorStub { _ in
                        makeWorkflowGenerationResult()
                    }
                },
                now: { Date(timeIntervalSince1970: 2_000) }
            )
        )
        workflow.onEvent = { eventRecorder.record($0) }

        let outcome = await workflow.generate(
            request: makeWorkflowRequest(
                item: initial,
                requestedOutputLanguage: ""
            ),
            history: history.access
        )

        try expect(
            isPersistenceFailure(outcome),
            "language persistence failure is typed"
        )
        try expect(
            eventRecorder.persistedItems.isEmpty,
            "failed language persistence emits no item event"
        )
        try expect(
            !workflow.consumePendingReveal(noteID: initial.id),
            "failed language persistence creates no pending reveal"
        )
    }

    @MainActor
    private static func testFailedAttemptPersistenceFailureIsTyped() async throws {
        let initial = makeWorkflowItem()
        let history = MeetingSummaryWorkflowHistoryRecorder(item: initial)
        history.failingPersistCalls = [1]
        let eventRecorder = MeetingSummaryWorkflowEventRecorder(history: history)
        let workflow = MeetingSummaryWorkflow(
            dependencies: .init(
                makeGenerator: { _ in
                    MeetingSummaryWorkflowGeneratorStub { _ in
                        throw MeetingSummaryError.outputRejected(
                            .languageMismatch,
                            modelID: "fallback/model"
                        )
                    }
                },
                now: { Date(timeIntervalSince1970: 2_000) }
            )
        )
        workflow.onEvent = { eventRecorder.record($0) }

        let outcome = await workflow.generate(
            request: makeWorkflowRequest(item: initial),
            history: history.access
        )

        try expect(
            isPersistenceFailure(outcome),
            "failed-attempt persistence failure is typed"
        )
        try expect(
            eventRecorder.persistedItems.isEmpty,
            "failed-attempt write emits no item event"
        )
        try expect(
            history.storedItem?.meetingSummaryAttempt == nil,
            "failed-attempt write does not mutate durable state"
        )
        try expect(
            !workflow.consumePendingReveal(noteID: initial.id),
            "failed attempt creates no pending reveal"
        )
    }

    @MainActor
    private static func testSuccessfulSummaryPersistenceFailureIsTyped() async throws {
        let initial = makeWorkflowItem()
        let history = MeetingSummaryWorkflowHistoryRecorder(item: initial)
        history.failingPersistCalls = [1]
        let eventRecorder = MeetingSummaryWorkflowEventRecorder(history: history)
        let workflow = MeetingSummaryWorkflow(
            dependencies: .init(
                makeGenerator: { _ in
                    MeetingSummaryWorkflowGeneratorStub { _ in
                        makeWorkflowGenerationResult()
                    }
                },
                now: { Date(timeIntervalSince1970: 2_000) }
            )
        )
        workflow.onEvent = { eventRecorder.record($0) }

        let outcome = await workflow.generate(
            request: makeWorkflowRequest(item: initial),
            history: history.access
        )

        try expect(
            isPersistenceFailure(outcome),
            "successful Summary persistence failure is typed"
        )
        try expect(
            eventRecorder.persistedItems.isEmpty,
            "failed Summary write emits no item event"
        )
        try expect(
            history.storedItem?.meetingSummary == nil,
            "failed Summary write does not mutate durable state"
        )
        try expect(
            !workflow.consumePendingReveal(noteID: initial.id),
            "failed Summary write creates no pending reveal"
        )
    }

    @MainActor
    private static func testNonDurableHistoryRejectsBeforeGeneration() async throws {
        let initial = makeWorkflowItem()
        let history = MeetingSummaryWorkflowHistoryRecorder(item: initial)
        history.durabilityValue = .inMemory
        let sourceRecorder = MeetingSummaryWorkflowSourceRecorder()
        let workflow = MeetingSummaryWorkflow(
            dependencies: .init(
                makeGenerator: { _ in
                    MeetingSummaryWorkflowGeneratorStub { source in
                        await sourceRecorder.record(source)
                        return makeWorkflowGenerationResult()
                    }
                },
                now: { Date(timeIntervalSince1970: 2_000) }
            )
        )

        let outcome = await workflow.generate(
            request: makeWorkflowRequest(item: initial),
            history: history.access
        )
        let source = await sourceRecorder.latest()

        try expect(
            isPersistenceFailure(outcome),
            "non-durable history is rejected as persistence failure"
        )
        try expect(
            source == nil,
            "non-durable history is rejected before generator creation"
        )
        try expect(
            history.persistedItems.isEmpty,
            "non-durable history receives no writes"
        )
        try expect(
            workflow.state == .initial,
            "non-durable rejection does not mutate workflow state"
        )
    }

    @MainActor
    private static func testStaleSuccessCompletionsAreRejected() async throws {
        for mutation in MeetingSummaryWorkflowStaleMutation.allCases {
            let initial = makeWorkflowItem()
            let history = MeetingSummaryWorkflowHistoryRecorder(item: initial)
            let generator = MeetingSummaryWorkflowControlledGenerator()
            let workflow = MeetingSummaryWorkflow(
                dependencies: .init(
                    makeGenerator: { _ in generator },
                    now: { Date(timeIntervalSince1970: 2_000) }
                )
            )
            let task = Task {
                await workflow.generate(
                    request: makeWorkflowRequest(item: initial),
                    history: history.access
                )
            }
            await generator.waitUntilStarted()

            mutation.apply(
                initialItem: initial,
                history: history,
                workflow: workflow
            )
            generator.complete(
                with: .success(makeWorkflowGenerationResult())
            )
            let outcome = await task.value

            try expect(
                isSourceChanged(outcome),
                "stale success is rejected after \(mutation.label)"
            )
            try expect(
                history.persistedItems.isEmpty,
                "stale success is not persisted after \(mutation.label)"
            )
            try expect(
                !workflow.state.generatingNoteIDs.contains(initial.id),
                "stale success finishes generation after \(mutation.label)"
            )
        }
    }

    @MainActor
    private static func testStaleFailureCompletionsAreRejected() async throws {
        for mutation in [
            MeetingSummaryWorkflowStaleMutation.replaceTranscript,
            .removeStoredNote
        ] {
            let previousAttempt = makeWorkflowAttempt(
                outcome: .succeeded,
                modelID: "previous/model"
            )
            let initial = makeWorkflowItem()
                .withMeetingSummaryAttempt(previousAttempt)
            let history = MeetingSummaryWorkflowHistoryRecorder(item: initial)
            let generator = MeetingSummaryWorkflowControlledGenerator()
            let workflow = MeetingSummaryWorkflow(
                dependencies: .init(
                    makeGenerator: { _ in generator },
                    now: { Date(timeIntervalSince1970: 2_000) }
                )
            )
            let task = Task {
                await workflow.generate(
                    request: makeWorkflowRequest(item: initial),
                    history: history.access
                )
            }
            await generator.waitUntilStarted()

            mutation.apply(
                initialItem: initial,
                history: history,
                workflow: workflow
            )
            generator.complete(
                with: .failure(
                    MeetingSummaryError.outputRejected(
                        .languageMismatch,
                        modelID: "failed/model"
                    )
                )
            )
            let outcome = await task.value

            try expect(
                isSourceChanged(outcome),
                "stale failure is rejected after \(mutation.label)"
            )
            try expect(
                history.persistedItems.isEmpty,
                "stale failure writes no attempt after \(mutation.label)"
            )
            if mutation == .replaceTranscript {
                try expect(
                    history.storedItem?.meetingSummaryAttempt
                        == previousAttempt,
                    "stale failure preserves the previous attempt"
                )
            }
            try expect(
                !workflow.state.generatingNoteIDs.contains(initial.id),
                "stale failure finishes generation after \(mutation.label)"
            )
        }
    }

    @MainActor
    private static func
        testStaleGenerationCannotClearNewerGenerationState() async throws
    {
        let initial = makeWorkflowItem()
        let history = MeetingSummaryWorkflowHistoryRecorder(item: initial)
        let firstGenerator = MeetingSummaryWorkflowControlledGenerator()
        let secondGenerator = MeetingSummaryWorkflowControlledGenerator()
        var generators: [any MeetingSummaryGenerating] = [
            firstGenerator,
            secondGenerator
        ]
        let workflow = MeetingSummaryWorkflow(
            dependencies: .init(
                makeGenerator: { _ in generators.removeFirst() },
                now: { Date(timeIntervalSince1970: 2_000) }
            )
        )
        let firstTask = Task {
            await workflow.generate(
                request: makeWorkflowRequest(item: initial),
                history: history.access
            )
        }
        await firstGenerator.waitUntilStarted()
        workflow.invalidate(noteID: initial.id)
        let secondTask = Task {
            await workflow.generate(
                request: makeWorkflowRequest(item: initial),
                history: history.access
            )
        }
        await secondGenerator.waitUntilStarted()

        firstGenerator.complete(
            with: .success(makeWorkflowGenerationResult())
        )
        let firstOutcome = await firstTask.value

        try expect(
            isSourceChanged(firstOutcome),
            "invalidated generation is stale"
        )
        try expect(
            workflow.state.generatingNoteIDs.contains(initial.id),
            "stale completion does not clear newer generation state"
        )

        secondGenerator.complete(
            with: .success(makeWorkflowGenerationResult())
        )
        let secondOutcome = await secondTask.value

        try expect(
            isVerifiedSuccess(secondOutcome),
            "newer generation still completes"
        )
        try expect(
            !workflow.state.generatingNoteIDs.contains(initial.id),
            "newer generation clears its own state"
        )
    }

    @MainActor
    private static func
        testMissingDurableStartRejectsCompletionAfterGeneratorRuns() async throws
    {
        let initial = makeWorkflowItem()
        let history = MeetingSummaryWorkflowHistoryRecorder(item: nil)
        let sourceRecorder = MeetingSummaryWorkflowSourceRecorder()
        let workflow = MeetingSummaryWorkflow(
            dependencies: .init(
                makeGenerator: { _ in
                    MeetingSummaryWorkflowGeneratorStub { source in
                        await sourceRecorder.record(source)
                        return makeWorkflowGenerationResult()
                    }
                },
                now: { Date(timeIntervalSince1970: 2_000) }
            )
        )

        let outcome = await workflow.generate(
            request: makeWorkflowRequest(item: initial),
            history: history.access
        )
        let source = await sourceRecorder.latest()

        try expect(
            source != nil,
            "the captured start item reaches the generator"
        )
        try expect(
            isSourceChanged(outcome),
            "a missing durable completion target is source changed"
        )
        try expect(
            history.persistedItems.isEmpty,
            "a missing durable target receives no write"
        )
    }
}

@MainActor
private final class MeetingSummaryWorkflowHistoryRecorder {
    var storedItem: PipelineHistoryItem?
    var durabilityValue: PipelineHistoryDurability = .durable
    var failingPersistCalls = Set<Int>()
    private var persistCallCount = 0
    private(set) var persistedItems: [PipelineHistoryItem] = []
    private(set) var operations: [String] = []

    init(item: PipelineHistoryItem?) {
        storedItem = item
    }

    var access: MeetingSummaryHistoryAccess {
        MeetingSummaryHistoryAccess(
            durability: { [weak self] in
                self?.durabilityValue ?? .inMemory
            },
            item: { [weak self] id in
                guard self?.storedItem?.id == id else { return nil }
                return self?.storedItem
            },
            persist: { [weak self] item, requiresDurableStore in
                guard let self else { return }
                persistCallCount += 1
                operations.append("persist-\(persistCallCount)")
                if failingPersistCalls.contains(persistCallCount) {
                    throw MeetingSummaryWorkflowTestFailure(
                        description: "intentional persistence failure"
                    )
                }
                if requiresDurableStore,
                   durabilityValue != .durable {
                    throw MeetingSummaryWorkflowTestFailure(
                        description: "durable store required"
                    )
                }
                storedItem = item
                persistedItems.append(item)
            }
        )
    }
}

@MainActor
private final class MeetingSummaryWorkflowEventRecorder {
    private let history: MeetingSummaryWorkflowHistoryRecorder
    private(set) var persistedItems: [PipelineHistoryItem] = []
    private(set) var itemEventsObservedAfterPersistence = true

    init(history: MeetingSummaryWorkflowHistoryRecorder) {
        self.history = history
    }

    func record(_ event: MeetingSummaryWorkflowEvent) {
        guard case .itemPersisted(let item) = event else { return }
        if history.persistedItems.last?.id != item.id {
            itemEventsObservedAfterPersistence = false
        }
        persistedItems.append(item)
    }
}

private actor MeetingSummaryWorkflowSourceRecorder {
    private var sources: [MeetingSummarySource] = []

    func record(_ source: MeetingSummarySource) {
        sources.append(source)
    }

    func latest() -> MeetingSummarySource? {
        sources.last
    }
}

private enum MeetingSummaryWorkflowStaleMutation:
    CaseIterable,
    Equatable
{
    case replaceTranscript
    case removeStoredNote
    case invalidate
    case forget
    case forgetAll

    var label: String {
        switch self {
        case .replaceTranscript:
            "transcript replacement"
        case .removeStoredNote:
            "note removal"
        case .invalidate:
            "invalidation"
        case .forget:
            "note forgetting"
        case .forgetAll:
            "full forgetting"
        }
    }

    @MainActor
    func apply(
        initialItem: PipelineHistoryItem,
        history: MeetingSummaryWorkflowHistoryRecorder,
        workflow: MeetingSummaryWorkflow
    ) {
        switch self {
        case .replaceTranscript:
            history.storedItem = makeWorkflowItem(
                id: initialItem.id,
                transcript: "Changed transcript."
            )
            .withMeetingSummary(initialItem.meetingSummary)
            .withMeetingSummaryAttempt(initialItem.meetingSummaryAttempt)
        case .removeStoredNote:
            history.storedItem = nil
        case .invalidate:
            workflow.invalidate(noteID: initialItem.id)
        case .forget:
            workflow.forget(noteID: initialItem.id)
        case .forgetAll:
            workflow.forgetAll()
        }
    }
}

private func makeWorkflowItem(
    id: UUID = UUID(),
    transcript: String = "Decision: ship Friday.",
    spokenLanguageCode: String? = "en",
    spokenLanguageResolution:
        SpokenLanguageResolutionSource? = .engineDetected
) -> PipelineHistoryItem {
    PipelineHistoryItem(
        id: id,
        timestamp: Date(timeIntervalSince1970: 1_000),
        rawTranscript: transcript,
        postProcessedTranscript: transcript,
        postProcessingPrompt: nil,
        contextSummary: "Excluded context",
        contextPrompt: nil,
        contextScreenshotDataURL: nil,
        contextScreenshotStatus: "No screenshot",
        postProcessingStatus: "Post-processing succeeded",
        debugStatus: "Done",
        customVocabulary: "",
        usedPostProcessing: false,
        transcriptionLanguageCode: "auto",
        spokenLanguageCode: spokenLanguageCode,
        spokenLanguageResolution: spokenLanguageResolution
    )
}

private func makeWorkflowEnvelope(
    actionID: UUID,
    completed: Bool
) -> MeetingSummaryEnvelope {
    MeetingSummaryEnvelope(
        schemaVersion: MeetingSummaryEnvelope.currentSchemaVersion,
        promptVersion: 1,
        generatedAt: Date(timeIntervalSince1970: 1_500),
        sourceFingerprint: String(repeating: "c", count: 64),
        modelID: "summary/model",
        backendKind: .cloud,
        content: MeetingSummaryContent(
            overview: MeetingSummaryEvidenceText(
                text: "Release review",
                sourceQuotes: ["Decision: ship Friday."]
            ),
            keyPoints: [],
            decisions: [],
            actionItems: [
                MeetingSummaryActionItem(
                    id: actionID,
                    task: "Write release notes",
                    owner: nil,
                    dueDate: nil,
                    sourceQuote: "Decision: ship Friday.",
                    isCompleted: completed
                )
            ],
            openQuestions: []
        )
    )
}

private func makeWorkflowGenerationResult(
    actionID: UUID = UUID(),
    evidenceVerification:
        MeetingSummaryEvidenceVerification = .verified
) -> MeetingSummaryGenerationResult {
    MeetingSummaryGenerationResult(
        draft: MeetingSummaryDraftContentV2(
            overview: MeetingSummaryEvidenceText(
                text: "Release review",
                sourceQuotes: ["Decision: ship Friday."]
            ),
            keyPoints: [],
            decisions: [],
            actionItems: [
                MeetingSummaryActionItem(
                    id: actionID,
                    task: "Write release notes",
                    owner: nil,
                    dueDate: nil,
                    sourceQuote: "Decision: ship Friday.",
                    isCompleted: false
                )
            ],
            openQuestions: []
        ),
        promptVersion: 1,
        modelID: "summary/model",
        backendKind: .cloud,
        evidenceVerification: evidenceVerification
    )
}

private func makeWorkflowAttempt(
    outcome: MeetingSummaryAttemptOutcome,
    modelID: String
) -> MeetingSummaryAttempt {
    MeetingSummaryAttempt(
        occurredAt: Date(timeIntervalSince1970: 1_750),
        outcome: outcome,
        backendKind: .cloud,
        modelID: modelID,
        providerHost: "api.example.com",
        language: MeetingSummaryLanguageContext(
            requestedOutputLanguage: "English",
            appliedLanguageCode: "en",
            resolutionSource: .configured
        ),
        issue: nil,
        sourceFingerprint: String(repeating: "d", count: 64)
    )
}

private func makeWorkflowGeneratorConfiguration()
    -> MeetingSummaryGeneratorConfiguration
{
    MeetingSummaryGeneratorConfiguration(
        backendExecutor: AIProcessingBackendExecutor(
            choice: .cloud(modelID: "summary/model"),
            cloudBaseURL: "https://api.example.com/openai/v1",
            cloudAPIKey: "test-key"
        ),
        cloudFallbackModelID: "summary/fallback"
    )
}

private func makeWorkflowRequest(
    item: PipelineHistoryItem,
    requestedOutputLanguage: String = "English"
) -> MeetingSummaryWorkflowRequest {
    MeetingSummaryWorkflowRequest(
        noteID: item.id,
        initialItem: item,
        requestedOutputLanguage: requestedOutputLanguage,
        configuredBackendKind: .cloud,
        configuredModelID: "summary/model",
        providerHost: "api.example.com",
        generatorConfiguration: makeWorkflowGeneratorConfiguration()
    )
}

private func isVerifiedSuccess(_ outcome: MeetingSummaryWorkflowOutcome) -> Bool {
    if case .verifiedSuccess = outcome { return true }
    return false
}

private func isUnverifiedSuccess(_ outcome: MeetingSummaryWorkflowOutcome) -> Bool {
    if case .unverifiedSuccess = outcome { return true }
    return false
}

private func isGenerationFailure(
    _ outcome: MeetingSummaryWorkflowOutcome,
    matching expected: MeetingSummaryError
) -> Bool {
    guard case .generationFailed(let error) = outcome,
          let summaryError = error as? MeetingSummaryError else {
        return false
    }
    return summaryError == expected
}

private func isPersistenceFailure(
    _ outcome: MeetingSummaryWorkflowOutcome
) -> Bool {
    if case .persistenceFailed = outcome { return true }
    return false
}

private func isSourceChanged(
    _ outcome: MeetingSummaryWorkflowOutcome
) -> Bool {
    if case .sourceChanged = outcome { return true }
    return false
}

private final class MeetingSummaryWorkflowGeneratorStub:
    MeetingSummaryGenerating,
    @unchecked Sendable
{
    typealias Operation = @Sendable (
        MeetingSummarySource
    ) async throws -> MeetingSummaryGenerationResult

    private let operation: Operation

    init(operation: @escaping Operation) {
        self.operation = operation
    }

    func generate(
        source: MeetingSummarySource
    ) async throws -> MeetingSummaryGenerationResult {
        try await operation(source)
    }
}

private final class MeetingSummaryWorkflowControlledGenerator:
    MeetingSummaryGenerating,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var continuation:
        CheckedContinuation<MeetingSummaryGenerationResult, Error>?
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var hasStarted = false

    func generate(
        source: MeetingSummarySource
    ) async throws -> MeetingSummaryGenerationResult {
        try await withCheckedThrowingContinuation { continuation in
            let waiters = lock.withLock {
                self.continuation = continuation
                hasStarted = true
                let values = startedWaiters
                startedWaiters.removeAll()
                return values
            }
            waiters.forEach { $0.resume() }
        }
    }

    func waitUntilStarted() async {
        if lock.withLock({ hasStarted }) { return }
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                if hasStarted { return true }
                startedWaiters.append(continuation)
                return false
            }
            if shouldResume { continuation.resume() }
        }
    }

    func complete(
        with result: Result<MeetingSummaryGenerationResult, Error>
    ) {
        let continuation = lock.withLock {
            let value = self.continuation
            self.continuation = nil
            return value
        }
        continuation?.resume(with: result)
    }
}

private extension NSLock {
    func withLock<Value>(
        _ body: () throws -> Value
    ) rethrows -> Value {
        lock()
        defer { unlock() }
        return try body()
    }
}

private struct MeetingSummaryWorkflowTestFailure:
    Error,
    CustomStringConvertible
{
    let description: String
}

private func expect(
    _ condition: @autoclosure () -> Bool,
    _ description: String
) throws {
    guard condition() else {
        throw MeetingSummaryWorkflowTestFailure(
            description: description
        )
    }
}
