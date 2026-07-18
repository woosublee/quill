import Foundation

enum InflightRecordingRecoveryAction: String, Equatable {
    case markRecoverable
    case finalizeSingleSource
    case reusePromotedArtifact
    case persistHistory
    case markFinalized
    case cleanupEligible
    case discard
    case manualRecoveryRequired
}

enum InflightRecordingRecoveryDiagnostic: String, Equatable, Hashable {
    case missingManifest
    case corruptManifest
    case unsupportedSchema
    case recordingIDMismatch
    case unsafeSourceFileName
    case missingSource
    case sourceTooShort
    case emptySource
    case missingPermanentArtifact
    case manifestBehind
    case sourceTruncated
    case oddTrailingByte
    case promotionConflict
}

struct InflightRecordingRecoveryCandidate: Equatable {
    let recordingID: UUID?
    let recordingDirectory: URL
    let action: InflightRecordingRecoveryAction
    let recoverableDataByteCount: UInt64?
    let promotion: RecordingPromotion?
    let protectedPermanentFileName: String?
    let diagnostics: Set<InflightRecordingRecoveryDiagnostic>
}

struct InflightRecordingRecovery {
    let store: RecordingJournalStore

    func scan() -> [InflightRecordingRecoveryCandidate] {
        let fileManager = FileManager.default
        guard let directories = try? fileManager.contentsOfDirectory(
            at: store.inflightDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else {
            return []
        }

        return directories
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map(scanDirectory)
    }

    private func scanDirectory(
        _ directory: URL
    ) -> InflightRecordingRecoveryCandidate {
        let directoryRecordingID: UUID?
        if directory.lastPathComponent.hasPrefix(".discarded-") {
            directoryRecordingID = UUID(
                uuidString: String(
                    directory.lastPathComponent.dropFirst(".discarded-".count)
                )
            )
        } else {
            directoryRecordingID = UUID(
                uuidString: directory.lastPathComponent
            )
        }
        let discardMarkerURL = directory.appendingPathComponent(
            RecordingJournalStore.discardMarkerFileName
        )
        if directory.lastPathComponent.hasPrefix(".discarded-")
            || FileManager.default.fileExists(atPath: discardMarkerURL.path) {
            return InflightRecordingRecoveryCandidate(
                recordingID: directoryRecordingID,
                recordingDirectory: directory,
                action: .discard,
                recoverableDataByteCount: nil,
                promotion: nil,
                protectedPermanentFileName: nil,
                diagnostics: []
            )
        }

        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            return manualCandidate(
                directory: directory,
                recordingID: directoryRecordingID,
                diagnostics: [.missingManifest]
            )
        }

        let manifest: RecordingJournalManifest
        do {
            let data = try Data(contentsOf: manifestURL)
            manifest = try RecordingJournalCoding.makeDecoder().decode(
                RecordingJournalManifest.self,
                from: data
            )
            try manifest.validate()
        } catch RecordingJournalError.unsupportedSchemaVersion {
            return manualCandidate(
                directory: directory,
                recordingID: directoryRecordingID,
                diagnostics: [.unsupportedSchema]
            )
        } catch RecordingJournalError.unsafeRelativeFileName {
            return manualCandidate(
                directory: directory,
                recordingID: directoryRecordingID,
                diagnostics: [.unsafeSourceFileName]
            )
        } catch {
            return manualCandidate(
                directory: directory,
                recordingID: directoryRecordingID,
                diagnostics: [.corruptManifest]
            )
        }

        guard directoryRecordingID == manifest.recordingID else {
            return manualCandidate(
                directory: directory,
                recordingID: manifest.recordingID,
                diagnostics: [.recordingIDMismatch]
            )
        }
        guard manifest.sources.count == 1,
              manifest.segments.count == 1,
              manifest.segments[0].sourceIDs == [manifest.sources[0].id] else {
            return manualCandidate(
                directory: directory,
                recordingID: manifest.recordingID,
                diagnostics: [.corruptManifest]
            )
        }

        let permanentURL = store.permanentURL(recordingID: manifest.recordingID)
        let permanentPromotion = try? RecordingCanonicalWAV.validateFile(at: permanentURL)
        if FileManager.default.fileExists(atPath: permanentURL.path), permanentPromotion == nil {
            return manualCandidate(
                directory: directory,
                recordingID: manifest.recordingID,
                diagnostics: [.promotionConflict]
            )
        }
        if (manifest.state == .promoted
                || manifest.state == .historyStored
                || manifest.state == .finalized),
           permanentPromotion == nil {
            return manualCandidate(
                directory: directory,
                recordingID: manifest.recordingID,
                diagnostics: [.missingPermanentArtifact]
            )
        }

        let sourceURL: URL
        do {
            sourceURL = try store.sourceURL(
                recordingID: manifest.recordingID,
                fileName: manifest.sources[0].fileName
            )
        } catch {
            return manualCandidate(
                directory: directory,
                recordingID: manifest.recordingID,
                diagnostics: [.unsafeSourceFileName]
            )
        }

        if !FileManager.default.fileExists(atPath: sourceURL.path) {
            if let permanentPromotion,
               manifest.state == .recording
                    || manifest.state == .stopping
                    || manifest.state == .recoverable {
                return InflightRecordingRecoveryCandidate(
                    recordingID: manifest.recordingID,
                    recordingDirectory: directory,
                    action: .reusePromotedArtifact,
                    recoverableDataByteCount: permanentPromotion.dataByteCount,
                    promotion: permanentPromotion,
                    protectedPermanentFileName: permanentPromotion.fileName,
                    diagnostics: []
                )
            }
            if let permanentPromotion {
                return stateCandidate(
                    manifest: manifest,
                    directory: directory,
                    promotion: permanentPromotion
                )
            }
            return manualCandidate(
                directory: directory,
                recordingID: manifest.recordingID,
                diagnostics: manifest.state == .promoted
                    || manifest.state == .historyStored
                    || manifest.state == .finalized
                    ? [.missingPermanentArtifact]
                    : [.missingSource]
            )
        }

        let sourceSize: UInt64
        do {
            sourceSize = try RecordingJournalDurability.fileSize(at: sourceURL)
        } catch {
            return manualCandidate(
                directory: directory,
                recordingID: manifest.recordingID,
                diagnostics: [.missingSource]
            )
        }
        guard sourceSize >= UInt64(RecordingCanonicalWAV.headerByteCount) else {
            return manualCandidate(
                directory: directory,
                recordingID: manifest.recordingID,
                diagnostics: [.sourceTooShort]
            )
        }

        let actualPayload = sourceSize - UInt64(RecordingCanonicalWAV.headerByteCount)
        let evenPayload = actualPayload - (actualPayload % UInt64(RecordingPCMFormat.canonical.bytesPerFrame))
        guard evenPayload > 0 else {
            return manualCandidate(
                directory: directory,
                recordingID: manifest.recordingID,
                diagnostics: [.emptySource]
            )
        }

        var diagnostics: Set<InflightRecordingRecoveryDiagnostic> = []
        let committed = manifest.sources[0].committedDataByteCount
        if evenPayload > committed {
            diagnostics.insert(.manifestBehind)
        } else if evenPayload < committed {
            diagnostics.insert(.sourceTruncated)
        }
        if actualPayload != evenPayload {
            diagnostics.insert(.oddTrailingByte)
        }
        guard committed > 0 else {
            return manualCandidate(
                directory: directory,
                recordingID: manifest.recordingID,
                diagnostics: diagnostics.union([.emptySource])
            )
        }
        guard evenPayload >= committed else {
            return manualCandidate(
                directory: directory,
                recordingID: manifest.recordingID,
                diagnostics: diagnostics
            )
        }

        if let permanentPromotion {
            let sourceMatchesDestination = permanentPromotion.dataByteCount == committed
            guard sourceMatchesDestination else {
                return manualCandidate(
                    directory: directory,
                    recordingID: manifest.recordingID,
                    diagnostics: diagnostics.union([.promotionConflict])
                )
            }
            if manifest.state == .recording
                || manifest.state == .stopping
                || manifest.state == .recoverable {
                return InflightRecordingRecoveryCandidate(
                    recordingID: manifest.recordingID,
                    recordingDirectory: directory,
                    action: .reusePromotedArtifact,
                    recoverableDataByteCount: committed,
                    promotion: permanentPromotion,
                    protectedPermanentFileName: permanentPromotion.fileName,
                    diagnostics: diagnostics
                )
            }
        }

        switch manifest.state {
        case .recording:
            return InflightRecordingRecoveryCandidate(
                recordingID: manifest.recordingID,
                recordingDirectory: directory,
                action: .markRecoverable,
                recoverableDataByteCount: committed,
                promotion: nil,
                protectedPermanentFileName: nil,
                diagnostics: diagnostics
            )
        case .stopping, .recoverable:
            return InflightRecordingRecoveryCandidate(
                recordingID: manifest.recordingID,
                recordingDirectory: directory,
                action: .finalizeSingleSource,
                recoverableDataByteCount: committed,
                promotion: nil,
                protectedPermanentFileName: nil,
                diagnostics: diagnostics
            )
        case .promoted, .historyStored, .finalized:
            guard let promotion = permanentPromotion ?? manifest.promotion else {
                return manualCandidate(
                    directory: directory,
                    recordingID: manifest.recordingID,
                    diagnostics: diagnostics.union([.missingSource])
                )
            }
            return stateCandidate(
                manifest: manifest,
                directory: directory,
                promotion: promotion,
                diagnostics: diagnostics
            )
        }
    }

    private func stateCandidate(
        manifest: RecordingJournalManifest,
        directory: URL,
        promotion: RecordingPromotion,
        diagnostics: Set<InflightRecordingRecoveryDiagnostic> = []
    ) -> InflightRecordingRecoveryCandidate {
        let action: InflightRecordingRecoveryAction
        switch manifest.state {
        case .promoted:
            action = .persistHistory
        case .historyStored:
            action = .markFinalized
        case .finalized:
            action = .cleanupEligible
        case .recording, .stopping, .recoverable:
            action = .reusePromotedArtifact
        }
        return InflightRecordingRecoveryCandidate(
            recordingID: manifest.recordingID,
            recordingDirectory: directory,
            action: action,
            recoverableDataByteCount: promotion.dataByteCount,
            promotion: promotion,
            protectedPermanentFileName: promotion.fileName,
            diagnostics: diagnostics
        )
    }

    private func manualCandidate(
        directory: URL,
        recordingID: UUID?,
        diagnostics: Set<InflightRecordingRecoveryDiagnostic>
    ) -> InflightRecordingRecoveryCandidate {
        InflightRecordingRecoveryCandidate(
            recordingID: recordingID,
            recordingDirectory: directory,
            action: .manualRecoveryRequired,
            recoverableDataByteCount: nil,
            promotion: nil,
            protectedPermanentFileName: recordingID.map {
                $0.uuidString.lowercased() + ".wav"
            },
            diagnostics: diagnostics
        )
    }
}
