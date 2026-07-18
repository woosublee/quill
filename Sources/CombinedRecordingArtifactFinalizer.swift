import Foundation

enum CombinedRecordingArtifactFinalizerError: Error, Equatable {
    case noRecoverableSources
    case unsupportedManifestShape
}

enum CombinedRecordingArtifactMode: Equatable {
    case combined
    case microphoneOnly
    case systemAudioOnly
}

struct FinalizedCombinedRecordingArtifact: Equatable {
    let recordingID: UUID
    let destinationURL: URL
    let promotion: RecordingPromotion
    let mode: CombinedRecordingArtifactMode
}

struct CombinedRecordingArtifactFinalizer {
    let store: RecordingJournalStore
    let mixdownService: AudioMixdownService

    func finalizeAndPromote(
        recordingID: UUID
    ) throws -> FinalizedCombinedRecordingArtifact {
        let manifest = try store.loadManifest(recordingID: recordingID)
        if manifest.state == .promoted,
           let promotion = manifest.promotion {
            let destinationURL = store.permanentURL(recordingID: recordingID)
            let validated = try RecordingCanonicalWAV.validateFile(at: destinationURL)
            guard validated == promotion else {
                throw RecordingArtifactFinalizerError.promotionConflict
            }
            return FinalizedCombinedRecordingArtifact(
                recordingID: recordingID,
                destinationURL: destinationURL,
                promotion: promotion,
                mode: try artifactMode(
                    recordingID: recordingID,
                    manifest: manifest
                )
            )
        }
        guard manifest.state == .stopping || manifest.state == .recoverable else {
            throw RecordingArtifactFinalizerError.invalidLifecycleState(manifest.state)
        }
        guard manifest.sourceMode == .combined,
              manifest.sources.count == 2,
              manifest.segments.count == 1 else {
            throw CombinedRecordingArtifactFinalizerError.unsupportedManifestShape
        }

        let sourceFinalizer = RecordingArtifactFinalizer(store: store)
        let microphoneSource = manifest.sources.first { $0.kind == .microphone }
        let systemAudioSource = manifest.sources.first { $0.kind == .systemAudio }
        guard let microphoneSource, let systemAudioSource else {
            throw CombinedRecordingArtifactFinalizerError.unsupportedManifestShape
        }
        let microphone = try finalizeUsableSource(
            sourceFinalizer: sourceFinalizer,
            recordingID: recordingID,
            source: microphoneSource
        )
        let systemAudio = try finalizeUsableSource(
            sourceFinalizer: sourceFinalizer,
            recordingID: recordingID,
            source: systemAudioSource
        )

        let temporaryURL: URL
        let mode: CombinedRecordingArtifactMode
        switch (microphone, systemAudio) {
        case let (.some(microphone), .some(systemAudio)):
            temporaryURL = try mixdownService.mix(
                microphoneURL: microphone.sourceURL,
                microphoneFrameOffset: microphone.firstCommittedFrameOffset,
                systemAudioURL: systemAudio.sourceURL,
                systemAudioFrameOffset: systemAudio.firstCommittedFrameOffset
            )
            mode = .combined
        case let (.some(microphone), .none):
            temporaryURL = try mixdownService.materialize(
                sourceURL: microphone.sourceURL,
                frameOffset: microphone.firstCommittedFrameOffset
            )
            mode = .microphoneOnly
        case let (.none, .some(systemAudio)):
            temporaryURL = try mixdownService.materialize(
                sourceURL: systemAudio.sourceURL,
                frameOffset: systemAudio.firstCommittedFrameOffset
            )
            mode = .systemAudioOnly
        case (.none, .none):
            throw CombinedRecordingArtifactFinalizerError.noRecoverableSources
        }
        defer {
            if FileManager.default.fileExists(atPath: temporaryURL.path) {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
        }

        let validated = try RecordingCanonicalWAV.validateFile(at: temporaryURL)
        let artifact = FinalizedRecordingArtifact(
            recordingID: recordingID,
            sourceURL: temporaryURL,
            destinationURL: store.permanentURL(recordingID: recordingID),
            dataByteCount: validated.dataByteCount,
            frameCount: validated.frameCount,
            removedTrailingData: false
        )
        let promotion = try sourceFinalizer.promote(artifact)
        _ = try store.transition(
            recordingID: recordingID,
            to: .promoted,
            promotion: promotion
        )
        return FinalizedCombinedRecordingArtifact(
            recordingID: recordingID,
            destinationURL: artifact.destinationURL,
            promotion: promotion,
            mode: mode
        )
    }

    private func artifactMode(
        recordingID: UUID,
        manifest: RecordingJournalManifest
    ) throws -> CombinedRecordingArtifactMode {
        let sourceFinalizer = RecordingArtifactFinalizer(store: store)
        let microphone: FinalizedRecordingJournalSource?
        if let source = manifest.sources.first(where: { $0.kind == .microphone }) {
            microphone = try finalizeUsableSource(
                sourceFinalizer: sourceFinalizer,
                recordingID: recordingID,
                source: source
            )
        } else {
            microphone = nil
        }
        let systemAudio: FinalizedRecordingJournalSource?
        if let source = manifest.sources.first(where: { $0.kind == .systemAudio }) {
            systemAudio = try finalizeUsableSource(
                sourceFinalizer: sourceFinalizer,
                recordingID: recordingID,
                source: source
            )
        } else {
            systemAudio = nil
        }
        switch (microphone, systemAudio) {
        case (.some, .some): return .combined
        case (.some, .none): return .microphoneOnly
        case (.none, .some): return .systemAudioOnly
        case (.none, .none):
            throw CombinedRecordingArtifactFinalizerError.noRecoverableSources
        }
    }

    private func finalizeUsableSource(
        sourceFinalizer: RecordingArtifactFinalizer,
        recordingID: UUID,
        source: RecordingJournalSource
    ) throws -> FinalizedRecordingJournalSource? {
        do {
            return try sourceFinalizer.finalizeSource(
                recordingID: recordingID,
                source: source
            )
        } catch RecordingArtifactFinalizerError.sourceMissing,
                RecordingArtifactFinalizerError.sourceTooShort,
                RecordingArtifactFinalizerError.emptyPayload,
                RecordingArtifactFinalizerError.committedPayloadUnavailable,
                RecordingArtifactFinalizerError.payloadTooLarge {
            return nil
        }
    }
}
