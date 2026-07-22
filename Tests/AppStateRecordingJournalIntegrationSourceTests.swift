import Foundation

@main
struct AppStateRecordingJournalIntegrationSourceTests {
    static func main() throws {
        let source = try String(
            contentsOfFile: "Sources/AppState.swift",
            encoding: .utf8
        )

        precondition(source.contains("private let recordingJournalStore: RecordingJournalStore"))
        precondition(source.contains("private var activeSegmentedJournalController: SegmentedRecordingJournalController?"))
        precondition(source.contains("private var activeRecordingID: UUID?"))
        precondition(source.contains("private var activeInputSwitchToken: UUID?"))
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
        precondition(source.contains("guard fileName != \"inflight\" else { continue }"))
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
        let initializerBody = try body(startingWith: "init()", in: source)
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
        precondition(startBody.contains("startPhysicalAudioRecorder(inputID: inputID)"))
        precondition(startBody.contains("controller.startCheckpointing"))
        precondition(!startBody.contains("SingleSourceRecordingJournalController"))
        precondition(!startBody.contains("CombinedRecordingJournalController"))

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
        let physicalStopRange = try requiredRange(
            of: "stopPhysicalAudioRecorder(",
            in: storageFailureBody
        )
        let finishFailureRange = try requiredRange(
            of: "finishRecordingAfterJournalPersistenceFailure(",
            in: storageFailureBody
        )
        precondition(preparationRange.lowerBound < physicalStopRange.lowerBound)
        precondition(physicalStopRange.lowerBound < finishFailureRange.lowerBound)

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
        precondition(switchBody.contains("activeInputSwitchToken = switchToken"))
        precondition(switchBody.contains("isActiveInputSwitchPhysicalStopInProgress = true"))
        precondition(switchBody.contains("isActiveInputSwitchPhysicalStopInProgress = false"))
        let stopRange = try requiredRange(of: "stopPhysicalAudioRecorder(", in: switchBody)
        let switchRange = try requiredRange(of: "controller.switchSegment(", in: switchBody)
        let startRange = try requiredRange(of: "startPhysicalAudioRecorder(inputID: newInputID)", in: switchBody)
        precondition(stopRange.lowerBound < switchRange.lowerBound)
        precondition(switchRange.lowerBound < startRange.lowerBound)
        precondition(switchBody.contains("controller.terminalPersistenceFailure"))
        precondition(switchBody.contains("activeRecordingStorageFailureID == controller.recordingID"))
        precondition(switchBody.contains("finishRecordingAfterJournalPersistenceFailure("))
        precondition(switchBody.contains("alreadyStoppedTemporaryURLs: temporaryURLs"))
        precondition(!switchBody.contains("discardSingleSourceJournal"))
        precondition(!switchBody.contains("removeInflightRecording"))

        let stopBody = try functionBody(named: "stopActiveAudioRecorder", in: source)
        precondition(stopBody.contains("stopPhysicalAudioRecorder("))
        precondition(stopBody.contains("detachSegmentedJournalSinks()"))
        precondition(stopBody.contains("finishStoppedSegmentedRecording("))

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
        precondition(cancelBody.contains("detachSegmentedJournalSinks()"))
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
        try testRecordOnlyBranchesBeforeTranscriptionJobCreation()
        try testAudioOnlyStopUsesExistingRecorderFinalizationCases()
        try testAudioOnlyStopDismissesRecordingOverlayOnErrors()
        try testAudioOnlyCompletionOwnsForegroundUIAndTermination()

        print("AppStateRecordingJournalIntegrationSourceTests passed")
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
        assert(helper.contains("savedAudioFileForStoppedRecording"))
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
                    activeRecordingTranscriptionEnabled = nil
                    return
                }
"""))
    }

    private static func testRecordOnlyStillStartsSelectedAudioRecorder() throws {
        let source = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)
        let begin = try body(startingWith: "private func beginRecording(", in: source)

        assert(begin.contains("try await self.startSelectedAudioRecorder(inputID: audioInputID)"))
        assert(begin.contains("self.audioLevelCancellable = self.activeRecorderAudioLevelPublisher"))
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
