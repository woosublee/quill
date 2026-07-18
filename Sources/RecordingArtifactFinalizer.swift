import Darwin
import Foundation

enum RecordingArtifactFinalizerError: Error, Equatable {
    case unsupportedManifestShape
    case invalidLifecycleState(RecordingJournalState)
    case sourceTooShort
    case emptyPayload
    case committedPayloadUnavailable
    case payloadTooLarge
    case promotionConflict
    case sourceMissing
    case systemCall(String, Int32)
}

struct FinalizedRecordingArtifact: Equatable {
    let recordingID: UUID
    let sourceURL: URL
    let destinationURL: URL
    let dataByteCount: UInt64
    let frameCount: UInt64
    let removedTrailingData: Bool
}

struct RecordingArtifactFinalizer {
    let store: RecordingJournalStore

    func finalizeSingleSource(
        recordingID: UUID
    ) throws -> FinalizedRecordingArtifact {
        let manifest = try store.loadManifest(recordingID: recordingID)
        guard manifest.state == .stopping || manifest.state == .recoverable else {
            throw RecordingArtifactFinalizerError.invalidLifecycleState(manifest.state)
        }
        guard manifest.sources.count == 1,
              manifest.segments.count == 1,
              manifest.segments[0].sourceIDs == [manifest.sources[0].id] else {
            throw RecordingArtifactFinalizerError.unsupportedManifestShape
        }

        let sourceURL = try store.sourceURL(
            recordingID: recordingID,
            fileName: manifest.sources[0].fileName
        )
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw RecordingArtifactFinalizerError.sourceMissing
        }
        let physicalSize = try RecordingJournalDurability.fileSize(at: sourceURL)
        let headerByteCount = UInt64(RecordingCanonicalWAV.headerByteCount)
        guard physicalSize >= headerByteCount else {
            throw RecordingArtifactFinalizerError.sourceTooShort
        }

        let committedPayloadSize = manifest.sources[0].committedDataByteCount
        guard committedPayloadSize > 0 else {
            throw RecordingArtifactFinalizerError.emptyPayload
        }
        let physicalPayloadSize = physicalSize - headerByteCount
        guard physicalPayloadSize >= committedPayloadSize else {
            throw RecordingArtifactFinalizerError.committedPayloadUnavailable
        }
        guard committedPayloadSize <= UInt64(UInt32.max - 36) else {
            throw RecordingArtifactFinalizerError.payloadTooLarge
        }

        let handle = try FileHandle(forUpdating: sourceURL)
        defer { try? handle.close() }
        if physicalPayloadSize != committedPayloadSize {
            try handle.truncate(
                atOffset: headerByteCount + committedPayloadSize
            )
        }
        try handle.seek(toOffset: 0)
        try handle.write(
            contentsOf: RecordingCanonicalWAV.header(
                dataByteCount: UInt32(committedPayloadSize)
            )
        )
        try RecordingJournalDurability.fullSync(handle.fileDescriptor)

        return FinalizedRecordingArtifact(
            recordingID: recordingID,
            sourceURL: sourceURL,
            destinationURL: store.permanentURL(recordingID: recordingID),
            dataByteCount: committedPayloadSize,
            frameCount: committedPayloadSize
                / UInt64(RecordingPCMFormat.canonical.bytesPerFrame),
            removedTrailingData: physicalPayloadSize != committedPayloadSize
        )
    }

    func promote(
        _ artifact: FinalizedRecordingArtifact
    ) throws -> RecordingPromotion {
        let promotion = RecordingPromotion(
            fileName: artifact.destinationURL.lastPathComponent,
            dataByteCount: artifact.dataByteCount,
            frameCount: artifact.frameCount
        )

        if FileManager.default.fileExists(atPath: artifact.destinationURL.path) {
            let existing: RecordingPromotion
            do {
                existing = try RecordingCanonicalWAV.validateFile(at: artifact.destinationURL)
            } catch {
                throw RecordingArtifactFinalizerError.promotionConflict
            }
            guard existing.dataByteCount == promotion.dataByteCount,
                  existing.frameCount == promotion.frameCount else {
                throw RecordingArtifactFinalizerError.promotionConflict
            }
            return promotion
        }

        guard FileManager.default.fileExists(atPath: artifact.sourceURL.path) else {
            throw RecordingArtifactFinalizerError.sourceMissing
        }

        let result = artifact.sourceURL.path.withCString { sourcePath in
            artifact.destinationURL.path.withCString { destinationPath in
                Darwin.renamex_np(sourcePath, destinationPath, UInt32(RENAME_EXCL))
            }
        }
        guard result == 0 else {
            if errno == EEXIST {
                return try promote(artifact)
            }
            throw RecordingArtifactFinalizerError.systemCall("renamex_np", errno)
        }
        try RecordingJournalDurability.syncDirectory(store.audioDirectory)
        try RecordingJournalDurability.syncDirectory(
            artifact.sourceURL.deletingLastPathComponent()
        )
        return promotion
    }
}
