import Foundation

struct RecordingRecoveryHistory {
    let journalStore: RecordingJournalStore
    let historyStore: PipelineHistoryStore

    func persist(
        _ recovered: RecoveredRecordingArtifact,
        maxCount: Int
    ) throws -> [DeletedPipelineHistoryAssets] {
        let loadedManifest: RecordingJournalManifest
        do {
            loadedManifest = try journalStore.loadManifest(
                recordingID: recovered.recordingID
            )
        } catch RecordingJournalStoreError.recordingNotFound {
            return []
        }
        var manifest = loadedManifest
        var deletedAssets: [DeletedPipelineHistoryAssets] = []
        if manifest.state == .promoted {
            let existingHistory = historyStore.loadAllHistory().first {
                $0.id == recovered.recordingID
            }
            if existingHistory?.isIncompleteTranscription != false {
                let item = makePlaceholder(from: recovered)
                deletedAssets = try historyStore.upsert(
                    item,
                    maxCount: maxCount
                )
            }
            manifest = try journalStore.transition(
                recordingID: recovered.recordingID,
                to: .historyStored,
                historyItemID: recovered.recordingID
            )
        }
        if manifest.state == .historyStored {
            _ = try journalStore.transition(
                recordingID: recovered.recordingID,
                to: .finalized
            )
        }
        try journalStore.removeInflightRecording(
            recordingID: recovered.recordingID
        )
        return deletedAssets
    }

    func makePlaceholder(
        from recovered: RecoveredRecordingArtifact
    ) -> PipelineHistoryItem {
        let manifest = recovered.manifest
        let pipeline = manifest.pipeline
        let recordingDuration = Double(recovered.promotion.frameCount)
            / Double(RecordingPCMFormat.canonical.sampleRate)
        let recordingEndedAt = manifest.startedAt.addingTimeInterval(
            recordingDuration
        )

        return PipelineHistoryItem.transcriptionRecoveryPlaceholder(
            id: recovered.recordingID,
            timestamp: recordingEndedAt,
            recordingStartedAt: manifest.startedAt,
            recordingEndedAt: recordingEndedAt,
            calendarMatch: calendarMatch(from: pipeline.calendar),
            intent: historyIntent(from: pipeline.intent),
            selectedText: pipeline.selectedText,
            capturedSelection: pipeline.selectedText,
            contextSummary: "",
            contextSystemPrompt: nil,
            contextPrompt: nil,
            contextScreenshotDataURL: nil,
            contextScreenshotStatus: "No screenshot",
            systemPrompt: pipeline.processing.customSystemPrompt,
            customVocabulary: pipeline.processing.customVocabulary.joined(
                separator: "\n"
            ),
            customSystemPrompt: pipeline.processing.customSystemPrompt ?? "",
            audioFileName: recovered.promotion.fileName,
            usedLocalTranscription: usesLocalTranscription(
                pipeline.transcription.backend
            ),
            usedContextCapture: pipeline.processing.contextCaptureEnabled,
            usedPostProcessing: pipeline.processing.postProcessingEnabled,
            transcriptionLanguageCode: pipeline.transcription.spokenLanguageCode,
            localTranscriptionModelID: pipeline.transcription.modelID
                ?? TranscriptionModel.default.id,
            contextAppName: nil,
            contextBundleIdentifier: nil,
            contextWindowTitle: nil
        )
    }

    private func historyIntent(
        from intent: RecordingIntentSnapshot
    ) -> PipelineHistoryItemIntent {
        switch intent {
        case .dictation:
            return .dictation
        case .commandAutomatic:
            return .commandAutomatic
        case .commandManual:
            return .commandManual
        }
    }

    private func usesLocalTranscription(
        _ backend: RecordingTranscriptionBackendSnapshot
    ) -> Bool {
        switch backend {
        case .nativeWhisper, .legacyMlxWhisper, .appleLive:
            return true
        case .apiStandard, .apiRealtime, .unknown:
            return false
        }
    }

    private func calendarMatch(
        from snapshot: RecordingCalendarSnapshot?
    ) -> CalendarEventMatch? {
        guard let snapshot,
              let eventID = snapshot.eventID,
              let calendarID = snapshot.calendarID,
              let start = snapshot.startDate,
              let end = snapshot.endDate else {
            return nil
        }
        let matchSource = snapshot.matchSource
            .flatMap(CalendarMatchSource.init(rawValue:))
            ?? .overlapSuggestion
        return CalendarEventMatch(
            calendarID: calendarID,
            eventID: eventID,
            title: snapshot.title ?? "",
            start: start,
            end: end,
            attendees: snapshot.attendeeNames.map {
                CalendarEventAttendee(displayName: $0)
            },
            matchSource: matchSource,
            titleState: .suggested
        )
    }
}
