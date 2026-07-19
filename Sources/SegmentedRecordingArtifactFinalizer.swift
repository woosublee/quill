import Foundation

enum SegmentedRecordingArtifactFinalizerError: Error, Equatable {
    case noRecoverableSegments
    case unsupportedManifestShape
}

struct FinalizedSegmentedRecordingArtifact: Equatable {
    let recordingID: UUID
    let destinationURL: URL
    let promotion: RecordingPromotion
    let mode: RecoveredRecordingMode
}

struct SegmentedRecordingArtifactFinalizer {
    let store: RecordingJournalStore
    let mixdownService: AudioMixdownService

    func finalizeAndPromote(
        recordingID: UUID
    ) throws -> FinalizedSegmentedRecordingArtifact {
        let manifest = try store.loadManifest(recordingID: recordingID)
        if manifest.state == .promoted, let promotion = manifest.promotion {
            let destinationURL = store.permanentURL(recordingID: recordingID)
            let validated: RecordingPromotion
            do {
                validated = try RecordingCanonicalWAV.validateFile(at: destinationURL)
            } catch {
                throw RecordingArtifactFinalizerError.promotionConflict
            }
            guard validated.fileName == promotion.fileName,
                  validated.dataByteCount == promotion.dataByteCount,
                  validated.frameCount == promotion.frameCount else {
                throw RecordingArtifactFinalizerError.promotionConflict
            }
            return FinalizedSegmentedRecordingArtifact(
                recordingID: recordingID,
                destinationURL: destinationURL,
                promotion: promotion,
                mode: promotion.resolvedRecoveryMode
            )
        }
        guard manifest.state == .stopping || manifest.state == .recoverable else {
            throw RecordingArtifactFinalizerError.invalidLifecycleState(manifest.state)
        }
        guard manifest.sourceMode == .segmented else {
            throw SegmentedRecordingArtifactFinalizerError.unsupportedManifestShape
        }

        let sourcesByID = Dictionary(
            uniqueKeysWithValues: manifest.sources.map { ($0.id, $0) }
        )
        let sourceFinalizer = RecordingArtifactFinalizer(store: store)
        var renderedSegments: [AudioMixdownSegment] = []
        var issues: [RecordingRecoveryIssue] = []

        for segment in manifest.segments.sorted(by: { $0.sequence < $1.sequence }) {
            guard (1...2).contains(segment.sourceIDs.count),
                  Set(segment.sourceIDs).count == segment.sourceIDs.count else {
                throw SegmentedRecordingArtifactFinalizerError.unsupportedManifestShape
            }
            let sources = try segment.sourceIDs.map { sourceID in
                guard let source = sourcesByID[sourceID],
                      source.segmentID == segment.id else {
                    throw SegmentedRecordingArtifactFinalizerError.unsupportedManifestShape
                }
                return source
            }
            guard Set(sources.map(\.kind)).count == sources.count else {
                throw SegmentedRecordingArtifactFinalizerError.unsupportedManifestShape
            }

            var usableByKind: [RecordingJournalSourceKind: FinalizedRecordingJournalSource] = [:]
            var segmentIssues: [RecordingRecoveryIssue] = []
            var hasCommittedOrDamagedAudio = false
            for source in sources {
                switch try resolveSource(
                    sourceFinalizer: sourceFinalizer,
                    recordingID: recordingID,
                    source: source
                ) {
                case .usable(let finalized):
                    usableByKind[source.kind] = finalized
                    hasCommittedOrDamagedAudio = true
                case .noCommittedAudio:
                    break
                case .unavailable(let reason):
                    hasCommittedOrDamagedAudio = true
                    segmentIssues.append(RecordingRecoveryIssue(
                        segmentSequence: segment.sequence,
                        sourceKind: source.kind,
                        reason: reason
                    ))
                }
            }

            if usableByKind.isEmpty {
                if hasCommittedOrDamagedAudio {
                    issues.append(contentsOf: segmentIssues)
                }
                continue
            }
            for source in sources
                where source.committedDataByteCount == 0
                    && usableByKind[source.kind] == nil {
                segmentIssues.append(RecordingRecoveryIssue(
                    segmentSequence: segment.sequence,
                    sourceKind: source.kind,
                    reason: .noCommittedAudio
                ))
            }
            issues.append(contentsOf: segmentIssues)
            renderedSegments.append(AudioMixdownSegment(
                microphone: usableByKind[.microphone].map {
                    AudioMixdownSource(
                        url: $0.sourceURL,
                        frameOffset: $0.firstCommittedFrameOffset
                    )
                },
                systemAudio: usableByKind[.systemAudio].map {
                    AudioMixdownSource(
                        url: $0.sourceURL,
                        frameOffset: $0.firstCommittedFrameOffset
                    )
                }
            ))
        }

        guard !renderedSegments.isEmpty else {
            throw SegmentedRecordingArtifactFinalizerError.noRecoverableSegments
        }
        issues.sort {
            if $0.segmentSequence != $1.segmentSequence {
                return $0.segmentSequence < $1.segmentSequence
            }
            return sourceOrder($0.sourceKind) < sourceOrder($1.sourceKind)
        }

        let recordingDirectory = store.recordingDirectory(recordingID: recordingID)
        let stagingURL = recordingDirectory.appendingPathComponent(
            ".assembled.wav.tmp"
        )
        if FileManager.default.fileExists(atPath: stagingURL.path) {
            try FileManager.default.removeItem(at: stagingURL)
            try RecordingJournalDurability.syncDirectory(recordingDirectory)
        }
        defer {
            if FileManager.default.fileExists(atPath: stagingURL.path) {
                try? FileManager.default.removeItem(at: stagingURL)
            }
        }

        _ = try mixdownService.assemble(renderedSegments, outputURL: stagingURL)
        let validated = try RecordingCanonicalWAV.validateFile(at: stagingURL)
        let handle = try FileHandle(forUpdating: stagingURL)
        do {
            try RecordingJournalDurability.fullSync(handle.fileDescriptor)
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        try RecordingJournalDurability.syncDirectory(recordingDirectory)

        let artifact = FinalizedRecordingArtifact(
            recordingID: recordingID,
            sourceURL: stagingURL,
            destinationURL: store.permanentURL(recordingID: recordingID),
            dataByteCount: validated.dataByteCount,
            frameCount: validated.frameCount,
            removedTrailingData: false
        )
        let physicalPromotion = try sourceFinalizer.promote(artifact)
        let mode: RecoveredRecordingMode = issues.isEmpty ? .complete : .partial
        let promotion = RecordingPromotion(
            fileName: physicalPromotion.fileName,
            dataByteCount: physicalPromotion.dataByteCount,
            frameCount: physicalPromotion.frameCount,
            recoveryMode: mode,
            recoveryIssues: issues.isEmpty ? nil : issues,
            interruptionReason: manifest.interruptionReason
        )
        _ = try store.transition(
            recordingID: recordingID,
            to: .promoted,
            promotion: promotion
        )
        return FinalizedSegmentedRecordingArtifact(
            recordingID: recordingID,
            destinationURL: artifact.destinationURL,
            promotion: promotion,
            mode: mode
        )
    }

    private enum SourceResolution {
        case usable(FinalizedRecordingJournalSource)
        case noCommittedAudio
        case unavailable(RecordingRecoveryIssueReason)
    }

    private func resolveSource(
        sourceFinalizer: RecordingArtifactFinalizer,
        recordingID: UUID,
        source: RecordingJournalSource
    ) throws -> SourceResolution {
        guard source.committedDataByteCount > 0 else {
            return .noCommittedAudio
        }
        do {
            return .usable(try sourceFinalizer.finalizeSource(
                recordingID: recordingID,
                source: source
            ))
        } catch RecordingArtifactFinalizerError.sourceMissing {
            return .unavailable(.sourceMissing)
        } catch RecordingArtifactFinalizerError.sourceTooShort {
            return .unavailable(.sourceTooShort)
        } catch RecordingArtifactFinalizerError.committedPayloadUnavailable {
            return .unavailable(.committedPayloadUnavailable)
        }
    }

    private func sourceOrder(_ kind: RecordingJournalSourceKind?) -> Int {
        switch kind {
        case .microphone: return 0
        case .systemAudio: return 1
        case nil: return 2
        }
    }
}
