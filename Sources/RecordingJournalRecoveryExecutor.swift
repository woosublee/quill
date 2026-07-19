import Foundation

struct RecoveredRecordingArtifact: Equatable {
    let recordingID: UUID
    let audioURL: URL
    let promotion: RecordingPromotion
    let manifest: RecordingJournalManifest
    let mode: RecoveredRecordingMode
}

enum RecordingJournalRecoveryResult: Equatable {
    case recovered(RecoveredRecordingArtifact)
    case discarded(UUID)
    case manualRecoveryRequired(InflightRecordingRecoveryCandidate)
    case failed(InflightRecordingRecoveryCandidate, String)
}

struct RecordingJournalRecoveryExecutor {
    let store: RecordingJournalStore

    func recoverAll() -> [RecordingJournalRecoveryResult] {
        InflightRecordingRecovery(store: store).scan().map(execute)
    }

    private func execute(
        _ candidate: InflightRecordingRecoveryCandidate
    ) -> RecordingJournalRecoveryResult {
        guard let recordingID = candidate.recordingID else {
            return .manualRecoveryRequired(candidate)
        }

        do {
            switch candidate.action {
            case .markRecoverable:
                _ = try store.transition(
                    recordingID: recordingID,
                    to: .recoverable
                )
                return try finalizeAndPromote(recordingID: recordingID)

            case .finalizeSingleSource:
                return try finalizeAndPromote(recordingID: recordingID)

            case .finalizeCombined:
                let manifest = try store.loadManifest(recordingID: recordingID)
                if manifest.state == .recording {
                    _ = try store.transition(
                        recordingID: recordingID,
                        to: .recoverable
                    )
                }
                do {
                    let artifact = try CombinedRecordingArtifactFinalizer(
                        store: store,
                        mixdownService: AudioMixdownService()
                    ).finalizeAndPromote(recordingID: recordingID)
                    return try recordPromotion(
                        recordingID: recordingID,
                        promotion: artifact.promotion
                    )
                } catch CombinedRecordingArtifactFinalizerError.noRecoverableSources {
                    return .manualRecoveryRequired(candidate)
                }

            case .reusePromotedArtifact:
                let promotion = try candidate.promotion
                    ?? RecordingCanonicalWAV.validateFile(
                        at: store.permanentURL(recordingID: recordingID)
                    )
                return try recordPromotion(
                    recordingID: recordingID,
                    promotion: promotion
                )

            case .persistHistory, .markFinalized, .cleanupEligible:
                let promotion = try candidate.promotion
                    ?? RecordingCanonicalWAV.validateFile(
                        at: store.permanentURL(recordingID: recordingID)
                    )
                let manifest = try store.loadManifest(recordingID: recordingID)
                return .recovered(RecoveredRecordingArtifact(
                    recordingID: recordingID,
                    audioURL: store.permanentURL(recordingID: recordingID),
                    promotion: promotion,
                    manifest: manifest,
                    mode: promotion.resolvedRecoveryMode
                ))

            case .discard:
                try store.discardInflightRecording(
                    recordingID: recordingID
                )
                return .discarded(recordingID)

            case .manualRecoveryRequired:
                return .manualRecoveryRequired(candidate)
            }
        } catch {
            return .failed(candidate, error.localizedDescription)
        }
    }

    private func finalizeAndPromote(
        recordingID: UUID
    ) throws -> RecordingJournalRecoveryResult {
        let finalizer = RecordingArtifactFinalizer(store: store)
        let artifact = try finalizer.finalizeSingleSource(
            recordingID: recordingID
        )
        let promotion = try finalizer.promote(artifact)
        return try recordPromotion(
            recordingID: recordingID,
            promotion: promotion
        )
    }

    private func recordPromotion(
        recordingID: UUID,
        promotion: RecordingPromotion
    ) throws -> RecordingJournalRecoveryResult {
        var manifest = try store.loadManifest(recordingID: recordingID)
        if manifest.state == .recording {
            manifest = try store.transition(
                recordingID: recordingID,
                to: .recoverable
            )
        }
        if manifest.state == .stopping || manifest.state == .recoverable {
            manifest = try store.transition(
                recordingID: recordingID,
                to: .promoted,
                promotion: promotion
            )
        }
        guard manifest.state == .promoted
                || manifest.state == .historyStored
                || manifest.state == .finalized else {
            throw RecordingArtifactFinalizerError.invalidLifecycleState(
                manifest.state
            )
        }
        return .recovered(RecoveredRecordingArtifact(
            recordingID: recordingID,
            audioURL: store.permanentURL(recordingID: recordingID),
            promotion: promotion,
            manifest: manifest,
            mode: manifest.promotion?.resolvedRecoveryMode
                ?? promotion.resolvedRecoveryMode
        ))
    }
}
