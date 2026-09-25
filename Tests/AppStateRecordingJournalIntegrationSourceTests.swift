import Foundation

@main
struct AppStateRecordingJournalIntegrationSourceTests {
    static func main() throws {
        let source = try String(
            contentsOfFile: "Sources/AppState.swift",
            encoding: .utf8
        )
        let appleSpeechSource = try String(
            contentsOfFile: "Sources/AppleSpeechLiveTranscriber.swift",
            encoding: .utf8
        )

        precondition(source.contains("private var recordingJournalStore: RecordingJournalStore"))
        precondition(source.contains("private var activeSegmentedJournalController: SegmentedRecordingJournalController?"))
        precondition(source.contains("private var activeRecordingID: UUID?"))
        precondition(source.contains("private var activeInputSwitchToken: UUID?"))
        precondition(source.contains("struct RecordingStartLifecycle"))
        precondition(source.contains("private var recordingStartAdmissionLifecycle = RecordingStartLifecycle()"))
        precondition(source.contains("private var physicalAudioStartLifecycle = RecordingStartLifecycle()"))
        precondition(source.contains("private var isActiveInputSwitchPhysicalStopInProgress = false"))
        precondition(source.contains("private var activeRecordingStorageFailureID: UUID?"))
        precondition(!source.contains("recordingSegmentURLs"))
        precondition(!source.contains("didSwitchInputDuringRecording"))
        precondition(!source.contains("stitchedRecordingURL"))
        precondition(!source.contains("discardRecordingSegments"))
        precondition(!source.contains("activeSingleSourceJournalController"))
        precondition(!source.contains("activeCombinedJournalController"))
        precondition(!source.contains("makeActiveSingleSourceJournalController"))
        precondition(!source.contains("makeActiveCombinedJournalController"))

        precondition(source.contains("recoverRecordingJournalsBeforeHistoryLoad"))
        precondition(source.contains("RecordingJournalRecoveryExecutor("))
        precondition(source.contains("RecordingRecoveryHistory("))
        precondition(source.contains("protectedInflightAudioFileNames("))
        precondition(source.contains("startupNoteAssetStore.sweepOrphans("))
        let startupRecoveryBody = try functionBody(
            named: "recoverRecordingJournalsBeforeHistoryLoad",
            in: source
        )
        for forbidden in [
            "retryTranscription",
            "transcribe(",
            "processTranscript",
            "PostProcessingService",
            "resolvedTranscriptionAPIKey",
            "provider",
            "upload"
        ] {
            precondition(!startupRecoveryBody.contains(forbidden))
        }
        let initializerBody = try body(
            startingWith: "init(dependencies: AppStateDependencies = .live)",
            in: source
        )
        let recoveryRange = try requiredRange(
            of: "recoverRecordingJournalsBeforeHistoryLoad(",
            in: initializerBody
        )
        let historyRange = try requiredRange(
            of: "pipelineHistoryStore.loadAllHistory()",
            in: initializerBody
        )
        precondition(recoveryRange.lowerBound < historyRange.lowerBound)

        let startBody = try functionBody(named: "startSelectedAudioRecorder", in: source)
        precondition(startBody.contains("makeActiveSegmentedJournalController(inputID: inputID)"))
        precondition(startBody.contains("attachSegmentedJournalSinks("))
        precondition(startBody.contains("startPhysicalAudioRecorder(selection: selection)"))
        precondition(startBody.contains("if let degradedSource"))
        precondition(startBody.contains("markDegradedJournalSourceUnavailableAtStart("))
        precondition(source.contains("selection: RecordingAudioSelection,\n        sessionID: UUID"))
        precondition(startBody.contains("let inputID = selection.inputID"))
        precondition(
            ranges(
                of: "isCurrentRecordingSession(sessionID)",
                in: startBody
            ).count == 2,
            "both success and failure cleanup must require the current active recording session"
        )
        precondition(!startBody.contains("guard activeRecordingID == sessionID"))
        precondition(startBody.contains("controller.startCheckpointing"))
        let terminalFailureRange = try requiredRange(
            of: "if let sourceFailure = controller.terminalPersistenceFailure",
            in: startBody
        )
        let terminalRecoveryRange = try requiredRange(
            of: "handleRecordingJournalPersistenceFailure(sourceFailure)",
            in: startBody
        )
        let failedStartCancelRange = try requiredRange(
            of: "await cancelPhysicalAudioRecorder(inputID: inputID)",
            in: startBody
        )
        let failedStartDiscardRange = try requiredRange(
            of: "discardSegmentedJournal(controller)",
            in: startBody
        )
        precondition(
            terminalFailureRange.lowerBound < terminalRecoveryRange.lowerBound
                && terminalRecoveryRange.lowerBound < failedStartCancelRange.lowerBound,
            "classified startup persistence failures enter recovery instead of discard"
        )
        precondition(
            failedStartCancelRange.lowerBound < failedStartDiscardRange.lowerBound,
            "a current unclassified failed start stops physical capture before discarding its journal"
        )
        precondition(!startBody.contains("SingleSourceRecordingJournalController"))
        precondition(!startBody.contains("CombinedRecordingJournalController"))

        let degradedSourceBody = try functionBody(
            named: "markDegradedJournalSourceUnavailableAtStart",
            in: source
        )
        precondition(degradedSourceBody.contains("case .microphone: .microphone"))
        precondition(degradedSourceBody.contains("case .systemAudio: .systemAudio"))
        precondition(degradedSourceBody.contains(
            "controller.markActiveSourceUnavailableAtStart(sourceKind)"
        ))
        let runtimeDegradedSourceBody = try functionBody(
            named: "markDegradedJournalSourceUnavailableDuringRecording",
            in: source
        )
        precondition(runtimeDegradedSourceBody.contains("case .microphone: .microphone"))
        precondition(runtimeDegradedSourceBody.contains("case .systemAudio: .systemAudio"))
        precondition(runtimeDegradedSourceBody.contains(
            "controller.markActiveSourceUnavailableDuringRecording(sourceKind)"
        ))
        let physicalStartBody = try functionBody(
            named: "startPhysicalAudioRecorder",
            in: source
        )
        precondition(physicalStartBody.contains("degradedSource = result.missingSource"))
        precondition(!physicalStartBody.contains(
            "degradedSource = systemDefaultAndSystemAudioRecorder.currentMissingSource"
        ))
        let firstReadyCheckpointBody = try functionBody(
            named: "checkpointCombinedRecordingJournalAfterFirstReady",
            in: source
        )
        precondition(firstReadyCheckpointBody.contains(
            "guard AudioInputDevice.isSystemDefaultAndSystemAudio(inputID) else"
        ))
        precondition(firstReadyCheckpointBody.contains(
            "controller.recordingID == sessionID"
        ))
        precondition(firstReadyCheckpointBody.contains("try controller.checkpoint()"))
        precondition(firstReadyCheckpointBody.contains(
            "reportRecordingJournalCheckpointFailure(error)"
        ))

        let makeControllerBody = try functionBody(
            named: "makeActiveSegmentedJournalController",
            in: source
        )
        precondition(makeControllerBody.contains("sourceMode: .segmented") == false)
        precondition(makeControllerBody.contains("SegmentedRecordingJournalCreateRequest("))
        precondition(makeControllerBody.contains("journalSourceRequests(for: inputID)"))
        precondition(makeControllerBody.contains("recordingPipelineSnapshot()"))
        precondition(makeControllerBody.contains("onTerminalPersistenceFailure:"))
        precondition(makeControllerBody.contains("handleRecordingJournalPersistenceFailure("))

        let storageFailureBody = try functionBody(
            named: "handleRecordingJournalPersistenceFailure",
            in: source
        )
        precondition(storageFailureBody.contains("guard isRecording,"))
        precondition(storageFailureBody.contains("activeRecordingTriggerMode != nil,"))
        precondition(storageFailureBody.contains("let physicalStopInProgress = isActiveInputSwitchPhysicalStopInProgress"))
        precondition(storageFailureBody.contains("if physicalStopInProgress { return }"))
        let preparationRange = try requiredRange(
            of: "prepareForRecordingJournalPersistenceFailure(sourceFailure)",
            in: storageFailureBody
        )
        let cleanupBeginRange = try requiredRange(
            of: "let cleanupID = beginPhysicalAudioCleanup()",
            in: storageFailureBody
        )
        let physicalStopRange = try requiredRange(
            of: "stopPhysicalAudioRecorder(",
            in: storageFailureBody
        )
        let cleanupFinishRange = try requiredRange(
            of: "physicalAudioStartLifecycle.finish(cleanupID)",
            in: storageFailureBody
        )
        let finishFailureRange = try requiredRange(
            of: "finishRecordingAfterJournalPersistenceFailure(",
            in: storageFailureBody
        )
        precondition(preparationRange.lowerBound < cleanupBeginRange.lowerBound)
        precondition(cleanupBeginRange.lowerBound < physicalStopRange.lowerBound)
        precondition(physicalStopRange.lowerBound < cleanupFinishRange.lowerBound)
        precondition(cleanupFinishRange.lowerBound < finishFailureRange.lowerBound)

        let alreadyStoppedFailureBody = try body(
            startingWith: "alreadyStoppedTemporaryURLs temporaryURLs: [URL]",
            in: source
        )
        let alreadyStoppedPreparationRange = try requiredRange(
            of: "prepareForRecordingJournalPersistenceFailure(sourceFailure)",
            in: alreadyStoppedFailureBody
        )
        let alreadyStoppedFinishRange = try requiredRange(
            of: "finishRecordingAfterJournalPersistenceFailure(",
            in: alreadyStoppedFailureBody
        )
        precondition(
            alreadyStoppedPreparationRange.lowerBound
                < alreadyStoppedFinishRange.lowerBound
        )

        let failurePreparationBody = try functionBody(
            named: "prepareForRecordingJournalPersistenceFailure",
            in: source
        )
        for required in [
            "activeRecordingStorageFailureID = sourceFailure.recordingID",
            "detachSegmentedJournalSinks()",
            "activeInputSwitchToken = nil",
            "isActiveInputSwitchPhysicalStopInProgress = false",
            "cancelPendingShortcutStart()",
            "cancelRecordingInitializationTimer()",
            "clearAudioRecorderCallbacks()",
            "audioLevelCancellable?.cancel()",
            "contextCaptureTask?.cancel()",
            "liveTranscriber?.cancel()",
            "tearDownRealtimeService()",
            "shortcutSessionController.reset()",
            "restoreAudioInterruptionIfNeeded()",
            "syncCriticalDictationActivity()",
            "sourceFailure.failure.reason.overlayLocalizationKey",
            "sourceFailure.failure.reason.titleLocalizationKey",
            "overlayManager.showRecordingNotice("
        ] {
            precondition(failurePreparationBody.contains(required))
        }

        let finishFailureBody = try functionBody(
            named: "finishRecordingAfterJournalPersistenceFailure",
            in: source
        )
        precondition(finishFailureBody.contains("recoverRecordingAfterJournalPersistenceFailure("))
        precondition(finishFailureBody.contains("controller.closeAfterPersistenceFailure()") == false)
        precondition(finishFailureBody.contains("SegmentedRecordingArtifactFinalizer(") == false)
        precondition(finishFailureBody.contains("completeRecordingStorageFailureRecovery("))
        let coreFailureRecoveryBody = try functionBody(
            named: "recoverRecordingAfterJournalPersistenceFailure",
            in: source
        )
        precondition(coreFailureRecoveryBody.contains("controller.closeAfterPersistenceFailure()"))
        precondition(coreFailureRecoveryBody.contains("SegmentedRecordingArtifactFinalizer("))

        let completeFailureBody = try functionBody(
            named: "completeRecordingStorageFailureRecovery",
            in: source
        )
        precondition(completeFailureBody.contains("RecordingRecoveryHistory("))
        precondition(completeFailureBody.contains("pipelineHistoryStore.loadAllHistory()"))
        precondition(completeFailureBody.contains("pipelineHistoryStore.delete(id:"))

        let storageBodies = storageFailureBody
            + alreadyStoppedFailureBody
            + failurePreparationBody
            + finishFailureBody
            + completeFailureBody
        for forbidden in [
            "stopAndTranscribe",
            "TranscriptionService",
            "resolveRawTranscript",
            "PostProcessingService",
            "resolvedTranscriptionAPIKey",
            "provider",
            "upload"
        ] {
            precondition(!storageBodies.contains(forbidden))
        }

        let switchBody = try functionBody(named: "switchActiveRecordingInput", in: source)
        let switchReadyCallback = try body(
            startingWith: "onReady: { [weak self] in",
            in: switchBody
        )
        precondition(switchReadyCallback.contains(
            "checkpointCombinedRecordingJournalAfterFirstReady("
        ))
        precondition(switchReadyCallback.contains("inputID: newInputID"))
        precondition(switchReadyCallback.contains(
            "sessionID: controller.recordingID"
        ))
        let switchDegradedCallback = try body(
            startingWith: "onDegraded: { [weak self] degradedSource in",
            in: switchBody
        )
        let switchRuntimeMarkerRange = try requiredRange(
            of: "markDegradedJournalSourceUnavailableDuringRecording(",
            in: switchDegradedCallback
        )
        let switchRuntimeNoticeRange = try requiredRange(
            of: "reconcileDegradedCombinedCaptureNotice(",
            in: switchDegradedCallback
        )
        precondition(
            switchRuntimeMarkerRange.lowerBound < switchRuntimeNoticeRange.lowerBound,
            "runtime source loss after an input switch is journaled before notice reconciliation"
        )
        precondition(switchBody.contains("activeInputSwitchToken = switchToken"))
        precondition(switchBody.contains("guard physicalAudioStartLifecycle.isIdle else"))
        precondition(switchBody.contains("physicalAudioStartLifecycle.begin(switchToken)"))
        precondition(switchBody.contains("rollbackStalePhysicalAudioStart("))
        precondition(switchBody.contains("isActiveInputSwitchPhysicalStopInProgress = true"))
        precondition(switchBody.contains("isActiveInputSwitchPhysicalStopInProgress = false"))
        let readinessGuardRange = try requiredRange(of: "guard isAudioInputSelectable(newInputID) else", in: switchBody)
        let switchTokenRange = try requiredRange(of: "let switchToken = UUID()", in: switchBody)
        precondition(readinessGuardRange.lowerBound < switchTokenRange.lowerBound)
        let stopRange = try requiredRange(of: "stopPhysicalAudioRecorder(", in: switchBody)
        let switchRange = try requiredRange(of: "controller.switchSegment(", in: switchBody)
        let startRange = try requiredRange(of: "startPhysicalAudioRecorder(selection: newSelection)", in: switchBody)
        precondition(switchBody.contains("if let degradedSource"))
        let degradedMarkerRange = try requiredRange(
            of: "markDegradedJournalSourceUnavailableAtStart(",
            in: switchBody
        )
        precondition(stopRange.lowerBound < switchRange.lowerBound)
        precondition(switchRange.lowerBound < startRange.lowerBound)
        precondition(startRange.lowerBound < degradedMarkerRange.lowerBound)
        let switchSessionGuardRanges = ranges(
            of: "self.isCurrentRecordingSession(controller.recordingID) else",
            in: switchBody
        )
        let switchReconcileRanges = ranges(
            of: "self.reconcileDegradedCombinedCaptureNotice(",
            in: switchBody
        )
        let switchReconcileRange = switchReconcileRanges.first {
            startRange.lowerBound < $0.lowerBound
        }
        let switchSessionGuardRange = switchSessionGuardRanges.first {
            guard let switchReconcileRange else { return false }
            return startRange.lowerBound < $0.lowerBound
                && $0.lowerBound < switchReconcileRange.lowerBound
        }
        precondition(switchBody.contains("sessionID: controller.recordingID"))
        precondition(
            switchSessionGuardRange != nil && switchReconcileRange != nil,
            "only the accepted current input switch can reconcile degraded-capture state"
        )

        // The live transcriber must be ended off the main thread so the
        // audio-source menu action returns immediately instead of stalling the
        // UI while an Apple Speech session is finalized/cancelled/deallocated.
        precondition(switchBody.contains("finishLiveTranscriberSegmentForInputSwitch()"))
        precondition(!switchBody.contains("liveTranscriber = nil"))
        let offMainTeardownBody = try functionBody(named: "finishLiveTranscriberSegmentForInputSwitch", in: source)
        precondition(offMainTeardownBody.contains("liveTranscriber = nil"))
        precondition(offMainTeardownBody.contains("DispatchQueue.global"))
        precondition(offMainTeardownBody.contains("transcriber.cancel()"))
        precondition(offMainTeardownBody.contains("Task.detached"))
        precondition(appleSpeechSource.contains("private struct State: @unchecked Sendable"))
        precondition(appleSpeechSource.contains("var finalizeContinuations: [CheckedContinuation<String, Error>] = []"))
        precondition(appleSpeechSource.contains("state.finalizeContinuations.append(continuation)"))
        precondition(appleSpeechSource.contains("for continuation in continuations"))
        precondition(!appleSpeechSource.contains("latestTranscript=%{public}@"))
        precondition(!appleSpeechSource.contains("text=%{public}@"))

        precondition(source.contains("func isAudioSourceSelectable(_ source: AudioRecordingSource) -> Bool"))
        let selectableBody = try functionBody(named: "isAudioSourceSelectable", in: source)
        precondition(selectableBody.contains("source == .microphoneAndSystemAudio"))
        precondition(selectableBody.contains("isRecording"))
        precondition(selectableBody.contains("isActiveRecordingUsingLiveOnlyTranscription"))
        let liveOnlyBody = try body(
            startingWith: "private var isActiveRecordingUsingLiveOnlyTranscription: Bool",
            in: source
        )
        precondition(liveOnlyBody.contains("currentNoteBrowserTranscriptionChoiceIsLiveOnly"))
        let choiceLiveOnlyBody = try body(
            startingWith: "private var currentNoteBrowserTranscriptionChoiceIsLiveOnly: Bool",
            in: source
        )
        precondition(choiceLiveOnlyBody.contains("case .appleLive, .apiRealtime:"))
        precondition(choiceLiveOnlyBody.contains("return true"))

        let overlayOptionsBody = try functionBody(named: "recordingOverlayInputOptions", in: source)
        precondition(overlayOptionsBody.contains("AudioRecordingSource.allCases.map"))
        precondition(overlayOptionsBody.contains("isEnabled: isAudioSourceSelectable(source)"))
        let overlayRefreshBody = try functionBody(named: "refreshOverlayInputOptions", in: source)
        precondition(overlayRefreshBody.contains("selectedID: selectedAudioSourceID"))
        precondition(switchBody.contains("controller.terminalPersistenceFailure"))
        precondition(switchBody.contains("activeRecordingStorageFailureID == controller.recordingID"))
        precondition(switchBody.contains("finishRecordingAfterJournalPersistenceFailure("))
        precondition(switchBody.contains("alreadyStoppedTemporaryURLs: temporaryURLs"))
        precondition(!switchBody.contains("discardSingleSourceJournal"))
        precondition(!switchBody.contains("removeInflightRecording"))

        let cleanupBody = try functionBody(
            named: "beginPhysicalAudioCleanup",
            in: source
        )
        precondition(cleanupBody.contains(
            "physicalAudioStartLifecycle.beginOrAdoptCleanup("
        ))

        let stopBody = try functionBody(named: "stopActiveAudioRecorder", in: source)
        precondition(stopBody.contains("let cleanupID = beginPhysicalAudioCleanup()"))
        precondition(stopBody.contains("stopPhysicalAudioRecorder("))
        precondition(stopBody.contains("detachSegmentedJournalSinks()"))
        precondition(stopBody.contains("finishStoppedSegmentedRecording("))
        precondition(stopBody.contains("physicalAudioStartLifecycle.finish(cleanupID)"))

        let finishBody = try functionBody(
            named: "finishStoppedSegmentedRecording",
            in: source
        )
        precondition(finishBody.contains("recordingJournalFinalizationQueue.async"))
        precondition(finishBody.contains("controller.stopAndClose()"))
        precondition(finishBody.contains("SegmentedRecordingArtifactFinalizer("))
        precondition(finishBody.contains("case .complete:"))
        precondition(finishBody.contains("case .partial:"))
        precondition(finishBody.contains("controller.terminalPersistenceFailure"))
        precondition(finishBody.contains("recoverRecordingAfterJournalPersistenceFailure("))
        precondition(finishBody.contains(".recoveredWithoutTranscription"))
        precondition(!finishBody.contains("temporaryCombinedFallback"))

        let stopAndTranscribeBody = try functionBody(named: "stopAndTranscribe", in: source)
        precondition(stopAndTranscribeBody.contains("guard activeRecordingStorageFailureID == nil else { return }"))
        precondition(stopAndTranscribeBody.contains("case .transcribable("))
        precondition(stopAndTranscribeBody.contains("case .recoveredWithoutTranscription(let recovered):"))
        precondition(stopAndTranscribeBody.contains("persistRecoveredRecordingWithoutTranscription("))
        precondition(stopAndTranscribeBody.contains("case .preservedForRecovery("))
        precondition(stopAndTranscribeBody.contains("case .empty:"))
        let partialBody = try switchCaseBody(
            startingWith: "case .recoveredWithoutTranscription(let recovered):",
            endingBefore: "case .preservedForRecovery",
            in: stopAndTranscribeBody
        )
        precondition(!partialBody.contains("TranscriptionService"))
        precondition(!partialBody.contains("resolveRawTranscript"))
        precondition(!partialBody.contains("PostProcessingService"))

        let cancelBody = try functionBody(named: "cancelActiveAudioRecorder", in: source)
        precondition(cancelBody.contains("let cleanupID = beginPhysicalAudioCleanup()"))
        precondition(cancelBody.contains("detachSegmentedJournalSinks()"))
        precondition(cancelBody.contains("physicalAudioStartLifecycle.finish(cleanupID)"))
        precondition(cancelBody.contains("discardActiveSegmentedJournal()"))

        let preserveBody = try functionBody(
            named: "preserveActiveSegmentedJournalForRecovery",
            in: source
        )
        precondition(preserveBody.contains("detachSegmentedJournalSinks()"))
        precondition(preserveBody.contains("controller.preserveForRecovery()"))

        try testRecordOnlySessionSnapshotsAndGatesAIComponents()
        try testAppleSpeechStartWithoutTriggerModeClearsSessionSnapshot()
        try testRecordOnlyStillStartsSelectedAudioRecorder()
        try testDegradedCombinedCaptureNoticeSessionWiring()
        try testRecordingStartCallbacksStaySessionScoped()
        try testDegradedCombinedCaptureNoticeEndsWithRecording()
        try testMCPStartReportsLifecycleRejection()
        try testSecondToggleCancelsPendingRecordingStart()
        try testPermissionResumeRetainsStartAdmission()
        try testCancelledPhysicalStartReleasesOnlyItsLifecycle()
        try testDuplicateCalendarReminderPreservesPendingSnapshot()
        try testRejectedRecordingEntryPointsResetShortcutSession()
        try testMCPStopUsesRecordingSessionSnapshot()
        try testRecordOnlyBranchesBeforeTranscriptionJobCreation()
        try testAudioOnlyStopUsesExistingRecorderFinalizationCases()
        try testAudioOnlyStopDismissesRecordingOverlayOnErrors()
        try testAudioOnlyHistoryFailureCleansOnlyUnreferencedNonJournalAudio()
        try testAudioOnlyCompletionOwnsForegroundUIAndTermination()
        try testPostProcessingStageIsTrackedPerNote()
        try testAppleLiveKeepsMainThreadUpdatesBounded()
        try testInputSwitchRestartsLiveTranscription()

        print("AppStateRecordingJournalIntegrationSourceTests passed")
    }

    // #354: the Note Browser labels post-processing apart from transcription.
    private static func testPostProcessingStageIsTrackedPerNote() throws {
        let source = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)
        let noteBrowser = try String(contentsOfFile: "Sources/NoteBrowserView.swift", encoding: .utf8)
        let menuBar = try String(contentsOfFile: "Sources/MenuBarView.swift", encoding: .utf8)
        let stop = try body(startingWith: "func stopAndTranscribe(", in: source)

        let marker = """
                        if capturedSettings.usedPostProcessing {
                            self.markTranscriptionJobPostProcessing(jobID)
                        }
"""
        precondition(stop.components(separatedBy: marker).count == 3, "both stop paths mark post-processing")
        let finish = try body(startingWith: "private func finishTranscriptionJob(_ id: UUID)", in: source)
        precondition(finish.contains("postProcessingNoteIDByJobID.removeValue(forKey: id)"))
        precondition(finish.contains("postProcessingNoteIDs.remove(noteID)"))
        precondition(noteBrowser.contains("postProcessingIDs: appState.postProcessingNoteIDs"))
        precondition(menuBar.contains("Label(appState.transcribingStatusTitle"))
        precondition(!menuBar.contains("Label(appState.debugStatusMessage"))
        // The menu bar describes the foreground job, not any job that is post-processing.
        let statusTitle = try body(startingWith: "var transcribingStatusTitle: String", in: source)
        precondition(statusTitle.contains("foregroundTranscriptionJobID.map"))
        precondition(statusTitle.contains("postProcessingNoteIDByJobID[$0] != nil"))
    }

    // #236: Apple Live callbacks must not flood the main thread while recording.
    private static func testAppleLiveKeepsMainThreadUpdatesBounded() throws {
        let source = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)
        let appleSpeechSource = try String(
            contentsOfFile: "Sources/AppleSpeechLiveTranscriber.swift",
            encoding: .utf8
        )
        let begin = try body(startingWith: "private func beginRecording(", in: source)
        let attach = try functionBody(named: "attachLiveTranscriber", in: source)

        precondition(begin.contains("self.attachLiveTranscriber("))

        // The active recorder already publishes the waveform level; the transcriber's
        // own level is only needed when it captures audio itself.
        precondition(attach.contains("""
        if transcriber.handlesRecording {
            transcriber.onAudioLevel = { [weak self] level in
"""))

        // Partial results are coalesced instead of replacing a published history
        // item on every recognizer callback.
        precondition(attach.contains("LiveTranscriptSegmentFeed("))
        precondition(attach.contains("interval: Self.liveTranscriptUpdateInterval"))
        precondition(attach.contains("feed.submit(text)"))
        precondition(attach.contains("self.currentRecordingLiveNoteID == liveNoteID"))
        precondition(!source.contains("""
                    transcriber.onPartialResult = { [weak self] text in
                        Task { @MainActor [weak self] in
"""))
        precondition(source.contains("static let liveTranscriptUpdateInterval: TimeInterval = 0.25"))

        let append = try body(startingWith: "    func appendPCM16(_ data: Data) {", in: appleSpeechSource)
        precondition(append.contains("guard let callback = state.onAudioLevel else"))
    }

    // #352: an input switch hands live transcription to a new transcriber instead of
    // silently dropping it until the recording stops.
    private static func testInputSwitchRestartsLiveTranscription() throws {
        let source = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)
        let switchBody = try functionBody(named: "switchActiveRecordingInput", in: source)

        precondition(switchBody.contains("let restartsLiveTranscription = finishLiveTranscriberSegmentForInputSwitch()"))
        precondition(!switchBody.contains("tearDownLiveTranscriberOffMainThread()"))
        // The replacement transcriber starts while the old recorder stops, and the new
        // recorder never waits for it, so no recorded audio is lost at the switch.
        guard let replacementStart = switchBody.range(of: "startReplacementLiveTranscriber("),
              let oldRecorderStop = switchBody.range(of: "stopPhysicalAudioRecorder(inputID: currentInputID)"),
              let newRecorderStart = switchBody.range(of: "try await self.startPhysicalAudioRecorder(selection: newSelection)") else {
            throw TestFailure("input switch live transcription restart wiring missing")
        }
        precondition(replacementStart.lowerBound < oldRecorderStop.lowerBound)
        precondition(!switchBody.contains("await self.restartLiveTranscriberAfterInputSwitch("))
        let recorderTask = String(switchBody[switchBody.range(of: "didHandOffReplacementLiveTranscriber = true")!.lowerBound...])
        guard let settle = recorderTask.range(of: "self.settleReplacementLiveTranscriber("),
              let recorderStart = recorderTask.range(of: "try await self.startPhysicalAudioRecorder(selection: newSelection)") else {
            throw TestFailure("replacement transcriber settle wiring missing")
        }
        // Settled from a defer, so it runs after the recorder start resolves.
        precondition(recorderTask[..<settle.lowerBound].contains("defer {"))
        precondition(settle.lowerBound < recorderStart.lowerBound)
        // Every exit before the recorder task still releases the replacement.
        precondition(switchBody.contains("if !didHandOffReplacementLiveTranscriber {"))

        let startReplacement = try functionBody(named: "startReplacementLiveTranscriber", in: source)
        precondition(startReplacement.contains("Task.detached"))
        precondition(startReplacement.contains("pendingRestartToken = switchToken"))
        let settleBody = try functionBody(named: "settleReplacementLiveTranscriber", in: source)
        precondition(settleBody.contains("self.activeInputSwitchToken == nil"))
        precondition(settleBody.contains("self.liveTranscriptionSession?.pendingRestartToken == switchToken"))
        precondition(settleBody.contains("markLiveTranscriptionIncomplete("))
        precondition(settleBody.contains("DispatchQueue.global"))

        let finish = try functionBody(named: "finishLiveTranscriberSegmentForInputSwitch", in: source)
        // Ending the old segment must stay off the main thread (#235).
        precondition(finish.contains("Task.detached"))
        precondition(finish.contains("try? await transcriber.finalize()"))
        precondition(finish.contains("session.feed?.finish()"))
        precondition(finish.contains("session.isRestartPending = true"))


        let stop = try body(startingWith: "func stopAndTranscribe(", in: source)
        precondition(stop.contains("let capturedLiveTranscriptionSession = liveTranscriptionSession"))
        precondition(stop.contains("try await Self.finalizeLiveTranscript("))
        precondition(!stop.contains("try await capturedLiveTranscriber?.finalize()"))

        let finalize = try functionBody(named: "finalizeLiveTranscript", in: source)
        precondition(finalize.contains("LiveTranscriptSegments.finalTranscript("))
        // Without a switch, the single transcriber keeps today's result and error behavior.
        precondition(finalize.contains("guard !finishedSegments.isEmpty || isIncomplete else {\n            return try await current?.finalize()"))
    }

    private static func testMCPStartReportsLifecycleRejection() throws {
        let source = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)
        let start = try body(startingWith: "private func startRecording(", in: source)
        let mcpStart = try body(startingWith: "func startRecordingFromMCP()", in: source)

        assert(source.contains("private func startRecording(\n        triggerMode: RecordingTriggerMode,\n        onStarted: (@MainActor () -> Void)? = nil\n    ) -> Bool"))
        assert(start.contains("guard physicalAudioStartLifecycle.isIdle else { return false }"))
        let admissionBegin = try requiredRange(
            of: "recordingStartAdmissionLifecycle.begin(startRequestID)",
            in: start
        )
        let taskStart = try requiredRange(of: "Task { [weak self] in", in: start)
        let admissionCompletion = try requiredRange(
            of: "completePendingRecordingStartTask(startRequestID)",
            in: start
        )
        assert(admissionBegin.lowerBound < taskStart.lowerBound)
        assert(taskStart.lowerBound < admissionCompletion.lowerBound)
        assert(start.contains("defer"))
        assert(start.contains("return true"))
        assert(mcpStart.contains("guard startRecording(triggerMode: .toggle) else"))
        assert(mcpStart.contains("shortcutSessionController.reset()"))
        assert(mcpStart.contains("return false"))
    }

    private static func testSecondToggleCancelsPendingRecordingStart() throws {
        let source = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)
        let start = try body(startingWith: "private func startRecording(", in: source)
        let toggle = try body(startingWith: "func toggleRecording()", in: source)
        let cancel = try functionBody(
            named: "cancelPendingRecordingStart",
            in: source
        )
        let cancelToggle = try functionBody(
            named: "cancelToggleShortcutSession",
            in: source
        )

        assert(source.contains(
            "private var pendingRecordingStartTask: Task<Void, Never>?"
        ))
        assert(start.contains("let startTask = Task { [weak self] in"))
        assert(start.contains("pendingRecordingStartTask = startTask"))
        assert(start.contains("recordingStartAdmissionLifecycle.activeID == startRequestID"))
        assert(start.contains("guard !Task.isCancelled else { return }"))
        assert(toggle.contains("if cancelPendingRecordingStart()"))
        assert(cancel.contains("pendingRecordingStartTask?.cancel()"))
        assert(cancel.contains("pendingRecordingStartTask = nil"))
        assert(cancel.contains("recordingStartAdmissionLifecycle.finish(startRequestID)"))
        assert(cancel.contains("restoreAudioInterruptionIfNeeded()"))
        let escapeAdmissionCancel = try requiredRange(
            of: "_ = cancelPendingRecordingStart()",
            in: cancelToggle
        )
        let escapeTriggerReset = try requiredRange(
            of: "activeRecordingTriggerMode = nil",
            in: cancelToggle
        )
        assert(
            escapeAdmissionCancel.lowerBound < escapeTriggerReset.lowerBound,
            "Escape cancellation invalidates the admitted async start before clearing UI state"
        )
    }

    private static func testPermissionResumeRetainsStartAdmission() throws {
        let source = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)
        let context = try body(
            startingWith: "private struct PendingRecordingPermissionContext",
            in: source
        )
        let start = try body(startingWith: "private func startRecording(", in: source)
        let complete = try functionBody(
            named: "completePendingRecordingStartTask",
            in: source
        )
        let microphoneAccess = try functionBody(
            named: "ensureMicrophoneAccess",
            in: source
        )
        let accessibleSelection = try functionBody(
            named: "accessibleCurrentRecordingAudioSelection",
            in: source
        )
        let speechPrompt = try functionBody(
            named: "prepareForSpeechRecognitionPermissionPrompt",
            in: source
        )
        let begin = try body(startingWith: "private func beginRecording(", in: source)

        assert(context.contains("let startRequestID: UUID"))
        assert(context.contains("let onStarted: (@MainActor () -> Void)?"))
        assert(start.contains(
            "completePendingRecordingStartTask(startRequestID)"
        ))
        assert(start.contains("guard !isAwaitingMicrophonePermission"))
        assert(start.contains("!isAwaitingSpeechRecognitionPermission"))
        assert(complete.contains("pendingMicrophonePermissionContext?.startRequestID"))
        assert(complete.contains("pendingSpeechPermissionContext?.startRequestID"))
        assert(microphoneAccess.contains(
            "recordingStartAdmissionLifecycle.activeID"
        ))
        assert(microphoneAccess.contains("== pendingContext.startRequestID"))
        assert(microphoneAccess.contains(
            "startRequestID: pendingContext.startRequestID"
        ))
        assert(microphoneAccess.contains(
            "onStarted: pendingContext.onStarted"
        ))
        assert(accessibleSelection.contains("onStarted: onStarted"))
        assert(speechPrompt.contains("startRequestID: startRequestID"))
        assert(speechPrompt.contains("onStarted: onStarted"))
        assert(source.contains(
            "private func beginRecording(\n        startRequestID: UUID"
        ))
        assert(begin.contains(
            "recordingStartAdmissionLifecycle.activeID == startRequestID"
        ))
    }

    private static func testCancelledPhysicalStartReleasesOnlyItsLifecycle() throws {
        let source = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)
        let cancel = try functionBody(named: "cancelActiveAudioRecorder", in: source)
        let rollback = try functionBody(
            named: "rollbackStalePhysicalAudioStart",
            in: source
        )

        assert(cancel.contains(
            "let cleanupID = beginPhysicalAudioCleanup()"
        ))
        assert(cancel.contains("physicalAudioStartLifecycle.finish(cleanupID)"))
        let finish = try requiredRange(
            of: "physicalAudioStartLifecycle.finish(cleanupID)",
            in: cancel
        )
        let discard = try requiredRange(
            of: "discardActiveSegmentedJournal()",
            in: cancel
        )
        assert(finish.lowerBound < discard.lowerBound)

        let ownershipGuard = try requiredRange(
            of: "physicalAudioStartLifecycle.beginCleanup(for: operationID)",
            in: rollback
        )
        let physicalCancel = try requiredRange(
            of: "cancelPhysicalAudioRecorder(inputID: inputID)",
            in: rollback
        )
        assert(ownershipGuard.lowerBound < physicalCancel.lowerBound)
    }

    private static func testDuplicateCalendarReminderPreservesPendingSnapshot() throws {
        let source = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)
        let initializer = try body(
            startingWith: "init(dependencies: AppStateDependencies = .live)",
            in: source
        )
        let calendarStart = try functionBody(
            named: "beginCalendarReminderRecording",
            in: source
        )
        let callbackStart = try requiredRange(
            of: "meetingReminderOverlayManager.onStart =",
            in: initializer
        )
        guard let callbackEnd = initializer.range(
            of: "self.startRecordingFromCalendarReminder()",
            range: callbackStart.upperBound..<initializer.endIndex
        ) else {
            throw TestFailure("missing calendar reminder start callback")
        }
        let callback = String(
            initializer[callbackStart.lowerBound..<callbackEnd.upperBound]
        )

        let callbackAdmissionGuard = try requiredRange(
            of: "recordingStartAdmissionLifecycle.isIdle",
            in: callback
        )
        let callbackSnapshot = try requiredRange(
            of: "activeRecordingCalendarSnapshot = RecordingCalendarSnapshot(",
            in: callback
        )
        assert(callbackAdmissionGuard.lowerBound < callbackSnapshot.lowerBound)
        assert(calendarStart.contains("recordingStartAdmissionLifecycle.isIdle"))
        assert(calendarStart.contains("physicalAudioStartLifecycle.isIdle"))
        let admissionGuard = try requiredRange(
            of: "recordingStartAdmissionLifecycle.isIdle",
            in: calendarStart
        )
        let rejectionCleanup = try requiredRange(
            of: "activeRecordingCalendarSnapshot = nil",
            in: calendarStart
        )
        assert(admissionGuard.lowerBound < rejectionCleanup.lowerBound)
    }

    private static func testRejectedRecordingEntryPointsResetShortcutSession() throws {
        let source = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)
        let toggle = try body(startingWith: "func toggleRecording()", in: source)
        let calendar = try functionBody(
            named: "beginCalendarReminderRecording",
            in: source
        )
        let shortcut = try functionBody(named: "scheduleShortcutStart", in: source)

        assert(toggle.contains("if !startRecording(triggerMode: .toggle)"))
        assert(toggle.contains("shortcutSessionController.reset()"))
        assert(calendar.contains("if !startRecording("))
        assert(calendar.contains("shortcutSessionController.reset()"))
        assert(calendar.contains("activeRecordingCalendarSnapshot = nil"))
        assert(
            ranges(of: "startRecording(triggerMode:", in: shortcut).count == 2
        )
        assert(
            ranges(of: "shortcutSessionController.reset()", in: shortcut).count == 2
        )
    }

    private static func testMCPStopUsesRecordingSessionSnapshot() throws {
        let source = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)
        let stop = try body(startingWith: "func stopRecordingFromMCP()", in: source)
        let snapshot = try requiredRange(
            of: "let shouldTranscribe = shouldTranscribeActiveRecording",
            in: stop
        )
        let stopCall = try requiredRange(of: "stopAndTranscribe()", in: stop)

        assert(source.contains("enum MCPStopRecordingOutcome"))
        assert(stop.contains("guard isRecording else { return .notRecording }"))
        assert(snapshot.lowerBound < stopCall.lowerBound)
        assert(stop.contains("return shouldTranscribe ? .transcribing : .savingAudioOnly"))
    }

    private static func testRecordOnlyBranchesBeforeTranscriptionJobCreation() throws {
        let source = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)
        let stop = try body(startingWith: "private func stopAndTranscribe()", in: source)

        let branchRange = try requiredRange(of: "if !shouldTranscribe", in: stop)
        let branch = try body(startingWith: "if !shouldTranscribe", in: stop)
        let register = try requiredRange(of: "registerTranscriptionJob(", in: stop)
        let overlay = try requiredRange(of: "overlayManager.showTranscribing()", in: stop)
        let service = try requiredRange(of: "PostProcessingService(", in: stop)

        assert(branchRange.lowerBound < register.lowerBound)
        assert(branchRange.lowerBound < overlay.lowerBound)
        assert(branchRange.lowerBound < service.lowerBound)
        assert(branch.contains("let audioOnlyOverlayID = overlayTranscriptionID"))
        assert(branch.contains("stopAndSaveAudioOnly("))
        assert(branch.contains("overlayID: audioOnlyOverlayID"))
        assert(!branch.contains("registerTranscriptionJob("))
        assert(!branch.contains("overlayManager.showTranscribing()"))
        assert(!branch.contains("PostProcessingService("))
    }

    private static func testAudioOnlyStopUsesExistingRecorderFinalizationCases() throws {
        let source = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)
        let helper = try body(startingWith: "private func stopAndSaveAudioOnly(", in: source)
        let persist = try body(startingWith: "private func persistAudioOnlyRecording(", in: source)

        assert(helper.contains("stopActiveAudioRecorder"))
        assert(helper.contains("case .transcribable"))
        assert(helper.contains("case .recoveredWithoutTranscription"))
        assert(helper.contains("case .preservedForRecovery"))
        assert(helper.contains("case .empty"))
        assert(helper.contains("try? noteAssetStore\n                    .adoptOrSaveStoppedAudio(from: fileURL)"))
        assert(!helper.contains("savedAudioFileForStoppedRecording"))
        assert(helper.contains("persistAudioOnlyRecording("))
        assert(persist.contains("PipelineHistoryItem.audioOnly("))
        assert(!helper.contains("PipelineHistoryItem.audioOnly("))
        assert(!helper.contains("saveTranscriptFile("))
        assert(!helper.contains("registerTranscriptionJob("))
        assert(!helper.contains("overlayManager.showTranscribing()"))
        assert(!helper.contains("writeTranscriptToPasteboard("))
        assert(!helper.contains("pasteAtCursorWhenShortcutReleased"))
        assert(!helper.contains("lastTranscript = \"\""))
    }

    private static func testAudioOnlyStopDismissesRecordingOverlayOnErrors() throws {
        let source = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)
        let helper = try body(startingWith: "private func stopAndSaveAudioOnly(", in: source)
        let transcribable = try switchCaseBody(
            startingWith: "case .transcribable",
            endingBefore: "case .recoveredWithoutTranscription",
            in: helper
        )
        let preserved = try switchCaseBody(
            startingWith: "case .preservedForRecovery",
            endingBefore: "case .empty",
            in: helper
        )
        let emptyRange = try requiredRange(of: "case .empty:", in: helper)
        let empty = String(helper[emptyRange.upperBound...])
        let persist = try body(startingWith: "private func persistAudioOnlyRecording(", in: source)

        for terminalPath in [transcribable, preserved, empty, persist] {
            assert(terminalPath.contains("completeStoppedRecording("))
            assert(terminalPath.contains("dismissTranscribingOverlay()"))
        }
    }

    private static func testAudioOnlyHistoryFailureCleansOnlyUnreferencedNonJournalAudio() throws {
        let source = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)
        let persist = try body(startingWith: "private func persistAudioOnlyRecording(", in: source)
        let catchRange = try requiredRange(of: "} catch {", in: persist)
        let catchBody = String(persist[catchRange.upperBound...])

        assert(catchBody.contains("journalRecordingID != nil"))
        assert(catchBody.contains("pipelineHistoryStore.availability == .ready"))
        assert(catchBody.contains("pipelineHistoryStore.durability == .durable"))
        assert(catchBody.contains("pipelineHistoryStore.verifyHistoryReadable()"))
        assert(catchBody.contains("pipelineHistoryStore.loadAllHistory()"))
        assert(catchBody.contains("audioOnlyPersistenceFailureCleanupDecision("))
        assert(catchBody.contains("audioFileIsReferenced = history.contains"))
        assert(catchBody.contains("recordingIDExistsInHistory: history.contains"))
        assert(catchBody.contains("cleanupDecision == .deleteUnreferencedAudio"))
        assert(catchBody.contains("noteAssetStore.deleteAudio("))
        assert(catchBody.contains("fileName: audioFileName"))
        assert(!catchBody.contains("deleteStoredFiles("))
        assert(!catchBody.contains("deleteAudioFile("))
    }

    private static func testAudioOnlyCompletionOwnsForegroundUIAndTermination() throws {
        let source = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)
        let begin = try body(startingWith: "private func beginRecording(", in: source)
        let stop = try body(startingWith: "private func stopAndSaveAudioOnly(", in: source)
        let persist = try body(startingWith: "private func persistAudioOnlyRecording(", in: source)
        let completion = try body(startingWith: "private func completeStoppedRecording(", in: source)
        let terminate = try body(startingWith: "private func terminateIfReady()", in: source)
        let requestTermination = try body(
            startingWith: "func requestTerminationWhileRecording()",
            in: source
        )

        let overlayOwner = try requiredRange(of: "overlayTranscriptionID = UUID()", in: begin)
        let clearedError = try requiredRange(of: "errorMessage = nil", in: begin)
        let pendingInsert = try requiredRange(
            of: "pendingAudioOnlyStopIDs.insert(recordingID)",
            in: stop
        )
        let recordingStopped = try requiredRange(of: "isRecording = false", in: stop)
        let historyAppend = try requiredRange(of: "appendPipelineHistoryItem(item)", in: persist)
        let persistenceCompletion = try requiredRange(of: "completeStoppedRecording(", in: persist)

        assert(source.contains("private var pendingAudioOnlyStopIDs: Set<UUID> = []"))
        assert(source.contains("private enum StoppedRecordingCompletion"))
        assert(begin.contains("overlayTranscriptionID = UUID()"))
        assert(overlayOwner.lowerBound < clearedError.lowerBound)
        assert(stop.contains("pendingAudioOnlyStopIDs.insert(recordingID)"))
        assert(pendingInsert.lowerBound < recordingStopped.lowerBound)
        assert(source.contains("calendarSnapshot: RecordingCalendarSnapshot?,\n        overlayID: UUID"))
        assert(source.contains("audioFileName: String,\n        overlayID: UUID"))
        assert(source.contains("completion: StoppedRecordingCompletion,\n        overlayID: UUID"))
        assert(completion.contains("cleanupActiveAudioRecordersIfIdle()"))
        assert(completion.contains("if overlayTranscriptionID == overlayID"))
        assert(completion.contains("updateOwnedUI()"))
        assert(completion.contains("pendingAudioOnlyStopIDs.remove(recordingID)"))
        assert(completion.contains("finishTranscriptionJob(jobID, overlayID: overlayID)"))
        assert(completion.contains("terminateIfReady()"))
        assert(terminate.contains("pendingAudioOnlyStopIDs.isEmpty"))
        assert(requestTermination.contains("pendingAudioOnlyStopIDs.isEmpty"))
        assert(historyAppend.lowerBound < persistenceCompletion.lowerBound)
    }

    private static func testRecordOnlySessionSnapshotsAndGatesAIComponents() throws {
        let source = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)
        let begin = try body(startingWith: "private func beginRecording(", in: source)

        assert(source.contains("private var activeRecordingTranscriptionEnabled: Bool?"))
        assert(begin.contains("activeRecordingTranscriptionEnabled = transcriptionEnabled"))
        assert(begin.contains("let recordingSessionID = UUID()"))
        assert(begin.contains("activeRecordingID = recordingSessionID"))
        assert(!begin.contains("AudioInputDevice.isSingleSource(audioInputID)"))
        assert(begin.contains("if shouldTranscribe"))
        assert(begin.contains("startRealtimeStreamingIfEnabled()"))
        assert(begin.contains("startContextCapture()"))
        assert(begin.contains("localTranscriptionModel.makeLiveTranscriber()"))
    }

    private static func testAppleSpeechStartWithoutTriggerModeClearsSessionSnapshot() throws {
        let source = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)
        let begin = try body(startingWith: "private func beginRecording(", in: source)

        assert(begin.contains("""
                guard let triggerMode = activeRecordingTriggerMode else {
                    activeRecordingID = nil
                    activeRecordingTranscriptionEnabled = nil
                    return
                }
"""))
        assert(begin.contains("""
                    guard let pendingContext else {
                        if self.pendingRecordingStartCount > 0 {
                            self.pendingRecordingStartCount -= 1
                        }
                        return
                    }
"""))
        assert(begin.contains(
            "recordingStartAdmissionLifecycle.activeID\n                            == pendingContext.startRequestID"
        ))
        assert(begin.contains("""
                    } else {
                        self.restoreAudioInterruptionIfNeeded()
                        self.activeRecordingCalendarSnapshot = nil
                        self.activeRecordingID = nil
"""))
        assert(begin.contains("""
            default:
                isRecording = false
                activeRecordingCalendarSnapshot = nil
                activeRecordingID = nil
"""))
        let promptPreparation = try functionBody(
            named: "prepareForSpeechRecognitionPermissionPrompt",
            in: source
        )
        assert(promptPreparation.contains("activeRecordingID = nil"))
    }

    private static func testRecordOnlyStillStartsSelectedAudioRecorder() throws {
        let source = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)
        let begin = try body(startingWith: "private func beginRecording(", in: source)

        assert(begin.contains("try await self.startSelectedAudioRecorder("))
        assert(begin.contains("sessionID: recordingSessionID"))
        assert(begin.contains("self.audioLevelCancellable = self.activeRecorderAudioLevelPublisher"))
    }

    private static func testDegradedCombinedCaptureNoticeSessionWiring() throws {
        let source = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)
        let begin = try body(startingWith: "private func beginRecording(", in: source)
        let sessionCreationRange = try requiredRange(of: "let recordingSessionID = UUID()", in: begin)
        let activeIDRange = try requiredRange(of: "activeRecordingID = recordingSessionID", in: begin)
        let recordingRange = try requiredRange(of: "isRecording = true", in: begin)
        let beginNoticeRange = try requiredRange(
            of: "overlayManager.beginDegradedCombinedCaptureNoticeSession(recordingSessionID)",
            in: begin
        )
        precondition(sessionCreationRange.lowerBound < activeIDRange.lowerBound)
        precondition(activeIDRange.lowerBound < recordingRange.lowerBound)
        precondition(
            recordingRange.lowerBound < beginNoticeRange.lowerBound,
            "the degraded-notice session begins only after recording is active"
        )

        let startRanges = ranges(
            of: "let degradedSource = try await self.startSelectedAudioRecorder(",
            in: begin
        )
        let sessionGuardRanges = ranges(
            of: "guard self.isCurrentRecordingSession(recordingSessionID) else",
            in: begin
        )
        let reconcileRanges = ranges(
            of: "self.reconcileDegradedCombinedCaptureNotice(",
            in: begin
        )
        precondition(startRanges.count == 2)
        precondition(sessionGuardRanges.count >= 2)
        precondition(reconcileRanges.count >= 2)
        for startRange in startRanges {
            let reconcileRange = reconcileRanges.first {
                startRange.lowerBound < $0.lowerBound
            }
            let guardRange = sessionGuardRanges.first {
                guard let reconcileRange else { return false }
                return startRange.lowerBound < $0.lowerBound
                    && $0.lowerBound < reconcileRange.lowerBound
            }
            precondition(
                guardRange != nil && reconcileRange != nil,
                "both start paths reject stale sessions before reconciling the notice"
            )
        }

        let reconcile = try functionBody(named: "reconcileDegradedCombinedCaptureNotice", in: source)
        precondition(reconcile.contains("let message = degradedSource.map"))
        precondition(reconcile.contains("overlayManager.reconcileDegradedCombinedCaptureNotice("))
        precondition(reconcile.contains("message: message"))
        precondition(reconcile.contains("sessionID: sessionID"))
        precondition(!reconcile.contains("guard let degradedSource else { return }"))
        precondition(source.contains(
            "manager.onVisibleOverlayFrameChange = { [weak self] frame in"
        ))
        precondition(source.contains(
            "self?.overlayManager.recordingReminderFrameDidChange(frame)"
        ))
    }

    private static func testRecordingStartCallbacksStaySessionScoped() throws {
        let source = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)
        let start = try body(startingWith: "private func startRecording(", in: source)
        let begin = try body(startingWith: "private func beginRecording(", in: source)
        let configure = try functionBody(
            named: "configureSelectedAudioRecorderCallbacks",
            in: source
        )
        let rollback = try functionBody(
            named: "rollbackStalePhysicalAudioStart",
            in: source
        )
        let beginCleanup = try functionBody(
            named: "beginPhysicalAudioCleanup",
            in: source
        )
        let readyCallback = try body(
            startingWith: "onReady: { [weak self] in",
            in: begin
        )
        let degradedCallback = try body(
            startingWith: "onDegraded: { [weak self] degradedSource in",
            in: begin
        )
        let takeLiveTranscriber = try functionBody(
            named: "takeLiveTranscriberIfOwned",
            in: source
        )
        let currentSession = try functionBody(
            named: "isCurrentRecordingSession",
            in: source
        )

        assert(start.contains("guard physicalAudioStartLifecycle.isIdle else { return false }"))
        assert(begin.contains("physicalAudioStartLifecycle.isIdle else"))
        let lifecycleBegin = try requiredRange(
            of: "physicalAudioStartLifecycle.begin(recordingSessionID)",
            in: begin
        )
        let noticeBegin = try requiredRange(
            of: "overlayManager.beginDegradedCombinedCaptureNoticeSession(recordingSessionID)",
            in: begin
        )
        assert(lifecycleBegin.lowerBound < noticeBegin.lowerBound)
        assert(begin.contains("guard self.isCurrentRecordingSession(recordingSessionID) else { return }"))
        assert(begin.contains("noticeSessionID: recordingSessionID"))
        assert(begin.contains("self.attachLiveTranscriber("))
        let transcriberStart = try requiredRange(
            of: "try await transcriber.start(locale:",
            in: begin
        )
        let transcriberAssignment = try requiredRange(
            of: "self.attachLiveTranscriber(",
            in: begin
        )
        let transcriberStartupContinuation = String(
            begin[transcriberStart.upperBound..<transcriberAssignment.lowerBound]
        )
        assert(
            transcriberStartupContinuation.contains(
                "guard self.isCurrentRecordingSession(recordingSessionID) else"
            )
        )
        assert(begin.contains("self.rollbackStalePhysicalAudioStart("))
        assert(begin.contains("self.finishPhysicalAudioStart(recordingSessionID)"))
        assert(currentSession.contains("activeRecordingID == sessionID"))
        assert(currentSession.contains("isRecording"))
        assert(currentSession.contains("activeRecordingTriggerMode != nil"))
        assert(source.contains("onDegraded: ((DegradedCombinedCaptureSource) -> Void)? = nil"))
        assert(configure.contains("systemDefaultAndSystemAudioRecorder.onRecordingDegraded = onDegraded"))
        assert(takeLiveTranscriber.contains("current === transcriber"))
        assert(takeLiveTranscriber.contains("liveTranscriber = nil"))
        assert(begin.contains("takeLiveTranscriberIfOwned(transcriber)"))
        assert(readyCallback.contains(
            "checkpointCombinedRecordingJournalAfterFirstReady("
        ))
        assert(readyCallback.contains("inputID: audioInputID"))
        assert(readyCallback.contains("sessionID: recordingSessionID"))
        let runtimeMarkerRange = try requiredRange(
            of: "markDegradedJournalSourceUnavailableDuringRecording(",
            in: degradedCallback
        )
        let runtimeNoticeRange = try requiredRange(
            of: "reconcileDegradedCombinedCaptureNotice(",
            in: degradedCallback
        )
        assert(runtimeMarkerRange.lowerBound < runtimeNoticeRange.lowerBound)
        assert(beginCleanup.contains(
            "physicalAudioStartLifecycle.beginOrAdoptCleanup("
        ))
        assert(rollback.contains(
            "physicalAudioStartLifecycle.beginCleanup(for: operationID)"
        ))
        assert(rollback.contains("cancelPhysicalAudioRecorder(inputID: inputID)"))
        assert(rollback.contains("physicalAudioStartLifecycle.finish(operationID)"))
    }

    private static func testDegradedCombinedCaptureNoticeEndsWithRecording() throws {
        let source = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)
        let stop = try functionBody(named: "stopAndTranscribe", in: source)
        let stopEndRange = try requiredRange(
            of: "overlayManager.endDegradedCombinedCaptureNoticeSession()",
            in: stop
        )
        let audioOnlyBranchRange = try requiredRange(of: "if !shouldTranscribe", in: stop)
        precondition(
            stopEndRange.lowerBound < audioOnlyBranchRange.lowerBound,
            "the degraded notice ends before transcription or audio-only saving begins"
        )

        let storageFailure = try functionBody(
            named: "prepareForRecordingJournalPersistenceFailure",
            in: source
        )
        let storageEndRange = try requiredRange(
            of: "overlayManager.endDegradedCombinedCaptureNoticeSession()",
            in: storageFailure
        )
        let recordingStoppedRange = try requiredRange(of: "isRecording = false", in: storageFailure)
        let storageNoticeRange = try requiredRange(of: "overlayManager.showRecordingNotice(", in: storageFailure)
        precondition(storageEndRange.lowerBound < recordingStoppedRange.lowerBound)
        precondition(
            storageEndRange.lowerBound < storageNoticeRange.lowerBound,
            "the stale degraded notice ends before the storage-failure notice is shown"
        )
    }

    private static func switchCaseBody(
        startingWith start: String,
        endingBefore end: String,
        in text: String
    ) throws -> String {
        guard let startRange = text.range(of: start),
              let endRange = text.range(
                of: end,
                range: startRange.upperBound..<text.endIndex
              ) else {
            throw TestFailure("missing switch case boundary")
        }
        return String(text[startRange.upperBound..<endRange.lowerBound])
    }

    private static func ranges(of needle: String, in text: String) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let range = text.range(of: needle, range: searchStart..<text.endIndex) {
            result.append(range)
            searchStart = range.upperBound
        }
        return result
    }

    private static func requiredRange(
        of needle: String,
        in text: String
    ) throws -> Range<String.Index> {
        guard let range = text.range(of: needle) else {
            throw TestFailure("missing text: \(needle)")
        }
        return range
    }

    private static func body(
        startingWith signature: String,
        in text: String
    ) throws -> String {
        guard let signatureRange = text.range(of: signature),
              let openBrace = text[signatureRange.upperBound...].firstIndex(of: "{") else {
            throw TestFailure("missing body starting with \(signature)")
        }
        return try body(after: openBrace, in: text)
    }

    private static func functionBody(named name: String, in text: String) throws -> String {
        let signatures = ["private func \(name)", "private static func \(name)", "func \(name)"]
        guard let signatureRange = signatures.compactMap({ text.range(of: $0) }).first,
              let openBrace = text[signatureRange.upperBound...].firstIndex(of: "{") else {
            throw TestFailure("missing function \(name)")
        }
        return try body(after: openBrace, in: text)
    }

    private static func body(
        after openBrace: String.Index,
        in text: String
    ) throws -> String {
        var depth = 0
        var index = openBrace
        while index < text.endIndex {
            switch text[index] {
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(text[text.index(after: openBrace)..<index])
                }
            default:
                break
            }
            index = text.index(after: index)
        }
        throw TestFailure("unterminated body")
    }

    private struct TestFailure: Error, CustomStringConvertible {
        let description: String

        init(_ description: String) {
            self.description = description
        }
    }
}
