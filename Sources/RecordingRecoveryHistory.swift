import Foundation

struct RecordingRecoveryHistory {
    let journalStore: RecordingJournalStore
    let historyStore: PipelineHistoryStore

    func persist(
        _ recovered: RecoveredRecordingArtifact,
        maxCount: Int
    ) throws -> [DeletedPipelineHistoryAssets] {
        guard FileManager.default.fileExists(atPath: recovered.audioURL.path) else {
            throw RecordingArtifactFinalizerError.sourceMissing
        }
        guard let physicalPromotion = try? RecordingCanonicalWAV.validateFile(
                at: recovered.audioURL
              ),
              physicalPromotion.fileName == recovered.promotion.fileName,
              physicalPromotion.dataByteCount == recovered.promotion.dataByteCount,
              physicalPromotion.frameCount == recovered.promotion.frameCount else {
            throw RecordingArtifactFinalizerError.promotionConflict
        }

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
            // A note kept for a recording that could not be recovered is
            // replaced by the recovered audio, like an unfinished note.
            if existingHistory == nil
                || existingHistory?.isIncompleteTranscription == true
                || existingHistory?.unrecoveredRecordingContext != nil {
                // Keep a title typed into the note while it was recording.
                let item = makePlaceholder(from: recovered)
                    .withCustomTitle(existingHistory?.customTitle)
                deletedAssets = try historyStore.upsert(
                    item,
                    maxCount: maxCount,
                    requiresDurableStore: true
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

    /// Applies one journal recovery result to history. A recording that
    /// cannot be recovered keeps a note that says what happened, instead of
    /// disappearing. A journal with no audio is removed once its note is
    /// saved, so it is not retried on every launch. A journal whose pieces
    /// remain is kept for Recover Again and the next launch.
    @discardableResult
    func apply(
        _ result: RecordingJournalRecoveryResult,
        maxCount: Int
    ) -> RecordingRecoveryApplyOutcome {
        apply(inspect(result), maxCount: maxCount) { recordingID in
            try journalStore.discardInflightRecording(recordingID: recordingID)
        }
    }

    /// Reads what `apply` needs from the journal folder. It touches only the
    /// file system, so it can run off the main thread.
    func inspect(
        _ result: RecordingJournalRecoveryResult
    ) -> RecordingRecoveryInspection {
        let candidate: InflightRecordingRecoveryCandidate
        switch result {
        case .manualRecoveryRequired(let manual):
            candidate = manual
        case .failed(let failed, _):
            candidate = failed
        case .recovered, .discarded:
            return RecordingRecoveryInspection(
                result: result,
                recordingID: nil,
                manifest: nil,
                journalHasAudio: true
            )
        }
        // A recording the user discarded is not shown again; its removal is
        // retried on the next launch. A journal whose folder does not match
        // its recording ID cannot be tied to one note or cleaned up safely.
        guard candidate.action != .discard,
              let recordingID = candidate.recordingID,
              candidate.recordingDirectory.standardizedFileURL.path
                == journalStore.recordingDirectory(recordingID: recordingID)
                    .standardizedFileURL.path else {
            return RecordingRecoveryInspection(
                result: result,
                recordingID: nil,
                manifest: nil,
                journalHasAudio: true
            )
        }
        return RecordingRecoveryInspection(
            result: result,
            recordingID: recordingID,
            manifest: try? journalStore.loadManifest(recordingID: recordingID),
            journalHasAudio: journalContainsAudio(
                directory: candidate.recordingDirectory,
                recordingID: recordingID
            )
        )
    }

    /// Applies one inspected result to history. `discardEmptyJournal` runs
    /// once the note for a journal with no audio is saved.
    @discardableResult
    func apply(
        _ inspection: RecordingRecoveryInspection,
        maxCount: Int,
        discardEmptyJournal: (UUID) throws -> Void
    ) -> RecordingRecoveryApplyOutcome {
        switch inspection.result {
        case .recovered(let artifact):
            do {
                return .recovered(try persist(artifact, maxCount: maxCount))
            } catch {
                // The stitched audio stays with its journal, which protects
                // it from the orphan sweep; the next launch saves it again
                // through the promoted artifact.
                let context = UnrecoveredRecordingContext(
                    kind: .recoveryFailed,
                    cause: UnrecoveredRecordingCause.classifying(error)
                )
                try? keepUnrecoveredNote(
                    recordingID: artifact.recordingID,
                    manifest: artifact.manifest,
                    directory: journalStore.recordingDirectory(
                        recordingID: artifact.recordingID
                    ),
                    context: context
                )
                return .unrecovered(artifact.recordingID, context)
            }
        case .discarded:
            return .discarded
        case .manualRecoveryRequired(let candidate):
            return keepUnrecovered(
                candidate,
                inspection: inspection,
                cause: nil,
                discardEmptyJournal: discardEmptyJournal
            )
        case .failed(let candidate, let cause):
            return keepUnrecovered(
                candidate,
                inspection: inspection,
                cause: cause,
                discardEmptyJournal: discardEmptyJournal
            )
        }
    }

    private func keepUnrecovered(
        _ candidate: InflightRecordingRecoveryCandidate,
        inspection: RecordingRecoveryInspection,
        cause: UnrecoveredRecordingCause?,
        discardEmptyJournal: (UUID) throws -> Void
    ) -> RecordingRecoveryApplyOutcome {
        guard let recordingID = inspection.recordingID else {
            return .skipped
        }
        let manifest = inspection.manifest
        guard inspection.journalHasAudio else {
            let context = UnrecoveredRecordingContext(
                kind: .noAudio,
                cause: manifest?.interruptionReason.map(
                    UnrecoveredRecordingCause.init(interruptionReason:)
                )
            )
            do {
                try keepUnrecoveredNote(
                    recordingID: recordingID,
                    manifest: manifest,
                    directory: candidate.recordingDirectory,
                    context: context
                )
                try discardEmptyJournal(recordingID)
            } catch {
                // Tried again on the next launch.
            }
            return .unrecovered(recordingID, context)
        }
        let context = UnrecoveredRecordingContext(
            kind: .recoveryFailed,
            cause: cause
        )
        try? keepUnrecoveredNote(
            recordingID: recordingID,
            manifest: manifest,
            directory: candidate.recordingDirectory,
            context: context
        )
        return .unrecovered(recordingID, context)
    }

    /// Whether the journal holds anything that could be recording audio: a
    /// file with more than a WAV header, or stitched audio already moved
    /// out of the journal. Unreadable folders count as holding audio.
    func journalContainsAudio(directory: URL, recordingID: UUID) -> Bool {
        let fileManager = FileManager.default
        if fileManager.fileExists(
            atPath: journalStore.permanentURL(recordingID: recordingID).path
        ) {
            return true
        }
        guard fileManager.fileExists(atPath: directory.path) else {
            return false
        }
        // Anything that cannot be read might be audio, so it keeps the
        // journal as pieces instead of letting it be discarded.
        var enumerationFailed = false
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [],
            errorHandler: { _, _ in
                enumerationFailed = true
                return true
            }
        ) else {
            return true
        }
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if name.hasPrefix("manifest")
                || name == RecordingJournalStore.discardMarkerFileName {
                continue
            }
            guard let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey]
            ) else {
                enumerationFailed = true
                continue
            }
            guard values.isRegularFile == true else { continue }
            if (values.fileSize ?? 0) > RecordingCanonicalWAV.headerByteCount {
                return true
            }
        }
        return enumerationFailed
    }

    /// Saves the note for a recording that could not be recovered. The
    /// note created when recording started is reused; a note that already
    /// holds a transcript or audio is left as it is.
    func keepUnrecoveredNote(
        recordingID: UUID,
        manifest: RecordingJournalManifest?,
        directory: URL,
        context: UnrecoveredRecordingContext
    ) throws {
        let history = historyStore.loadAllHistory()
        if let existing = history.first(where: { $0.id == recordingID }) {
            guard existing.isUnfinishedRecordingNote
                    || existing.unrecoveredRecordingContext != nil,
                  existing.postProcessingStatus != context.status else {
                return
            }
            try historyStore.update(
                existing.replacingUnrecoveredStatus(context),
                requiresDurableStore: true
            )
            return
        }

        let startedAt = manifest?.startedAt
            ?? (try? directory.resourceValues(
                forKeys: [.creationDateKey]
            ))?.creationDate
            ?? Date()
        // A recording note saved under another ID but started at the same
        // moment is the same recording; carry over its title.
        let startedTogether = manifest == nil ? nil : history.first {
            $0.isUnfinishedRecordingNote
                && abs(($0.recordingStartedAt ?? $0.timestamp)
                    .timeIntervalSince(startedAt)) < 5
        }
        let item = PipelineHistoryItem.unrecoveredRecording(
            id: recordingID,
            startedAt: startedAt,
            calendarMatch: calendarMatch(from: manifest?.pipeline.calendar)
                ?? startedTogether?.calendarMatch,
            customTitle: startedTogether?.customTitle,
            context: context
        )
        _ = try historyStore.upsert(
            item,
            maxCount: Int.max,
            requiresDurableStore: true
        )
        if let startedTogether {
            _ = try? historyStore.delete(id: startedTogether.id)
        }
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
            contextWindowTitle: nil,
            recoveryMode: recovered.mode,
            interruptionReason: recovered.interruptionReason
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
        case .nativeWhisper, .legacyMlxWhisper, .localAI, .appleLive:
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


/// What `RecordingRecoveryHistory.apply` needs from a journal folder,
/// read before history is changed.
struct RecordingRecoveryInspection {
    let result: RecordingJournalRecoveryResult
    /// Nil when the journal cannot be tied to one note.
    let recordingID: UUID?
    let manifest: RecordingJournalManifest?
    let journalHasAudio: Bool
}

enum RecordingRecoveryApplyOutcome {
    case recovered([DeletedPipelineHistoryAssets])
    case discarded
    case unrecovered(UUID, UnrecoveredRecordingContext)
    /// The journal was discarded, or cannot be matched to one note.
    case skipped
}

extension PipelineHistoryItem {
    static func unrecoveredRecording(
        id: UUID,
        startedAt: Date,
        calendarMatch: CalendarEventMatch?,
        customTitle: String?,
        context: UnrecoveredRecordingContext
    ) -> PipelineHistoryItem {
        PipelineHistoryItem(
            id: id,
            timestamp: startedAt,
            recordingStartedAt: startedAt,
            calendarMatch: calendarMatch,
            rawTranscript: "",
            postProcessedTranscript: "",
            postProcessingPrompt: nil,
            contextSummary: "",
            contextScreenshotDataURL: nil,
            contextScreenshotStatus: "No screenshot",
            postProcessingStatus: context.status,
            debugStatus: "Recording could not be recovered",
            customVocabulary: "",
            usedLocalTranscription: true,
            usedContextCapture: false,
            usedPostProcessing: false,
            customTitle: customTitle
        )
    }

    func replacingUnrecoveredStatus(
        _ context: UnrecoveredRecordingContext
    ) -> PipelineHistoryItem {
        PipelineHistoryItem(
            intent: intent,
            selectedText: selectedText,
            capturedSelection: capturedSelection,
            id: id,
            timestamp: timestamp,
            recordingStartedAt: recordingStartedAt,
            recordingEndedAt: recordingEndedAt,
            calendarMatch: calendarMatch,
            rawTranscript: rawTranscript,
            postProcessedTranscript: postProcessedTranscript,
            postProcessingPrompt: postProcessingPrompt,
            systemPrompt: systemPrompt,
            contextSummary: contextSummary,
            contextSystemPrompt: contextSystemPrompt,
            contextPrompt: contextPrompt,
            contextScreenshotDataURL: contextScreenshotDataURL,
            contextScreenshotStatus: contextScreenshotStatus,
            postProcessingStatus: context.status,
            aiProcessingOutcome: aiProcessingOutcome,
            debugStatus: "Recording could not be recovered",
            customVocabulary: customVocabulary,
            customSystemPrompt: customSystemPrompt,
            audioFileName: audioFileName,
            usedLocalTranscription: usedLocalTranscription,
            usedContextCapture: usedContextCapture,
            usedPostProcessing: usedPostProcessing,
            transcriptionLanguageCode: transcriptionLanguageCode,
            spokenLanguageCode: spokenLanguageCode,
            spokenLanguageResolution: spokenLanguageResolution,
            meetingSummaryAttempt: meetingSummaryAttempt,
            localTranscriptionModelID: localTranscriptionModelID,
            transcriptFileName: transcriptFileName,
            contextAppName: contextAppName,
            contextBundleIdentifier: contextBundleIdentifier,
            contextWindowTitle: contextWindowTitle,
            customTitle: customTitle,
            meetingSummaryJSON: meetingSummaryJSON,
            deletedAt: deletedAt,
            fieldClock: fieldClock
        )
    }
}
