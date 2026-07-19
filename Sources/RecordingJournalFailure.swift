import Darwin
import Foundation

enum RecordingJournalStoreError: Error, Equatable {
    case conflictingExistingRecording(UUID)
    case incompleteExistingRecording(UUID)
    case recordingNotFound(UUID)
    case sourceNotFound(UUID)
    case checkpointRegression
    case invalidCheckpointState(RecordingJournalState)
    case invalidSegmentSequence(expected: Int, actual: Int)
    case invalidSegmentSourceShape
    case conflictingExistingSegment(UUID)
    case invalidSourceFile
    case systemCall(String, Int32)
}

enum RecordingPCMJournalWriterError: Error, Equatable {
    case conflictingFrameOffset
    case oddByteChunk
    case writerClosed
    case writeFailed(String)
}

enum RecordingInterruptionReason: String, Codable, Equatable {
    case storageFull = "storage-full"
    case permissionDenied = "permission-denied"
    case journalIOFailure = "journal-io-failure"

    var titleLocalizationKey: String {
        switch self {
        case .storageFull: return "Recording stopped: storage full"
        case .permissionDenied: return "Recording stopped: storage unavailable"
        case .journalIOFailure: return "Recording stopped: save error"
        }
    }

    var causeDescriptionLocalizationKey: String {
        switch self {
        case .storageFull:
            return "Quill stopped recording because storage was full."
        case .permissionDenied:
            return "Quill stopped recording because audio storage was unavailable."
        case .journalIOFailure:
            return "Quill stopped recording because of an audio save error."
        }
    }

    var overlayLocalizationKey: String {
        switch self {
        case .storageFull:
            return "Recording stopped because storage is full. Free up space, then review the recovered audio."
        case .permissionDenied:
            return "Recording stopped because audio could not be saved. Check storage access, then review the recovered audio."
        case .journalIOFailure:
            return "Recording stopped because of an audio save error. Audio saved before the error is being recovered."
        }
    }
}

enum RecordingJournalPersistenceOperation: String, Equatable {
    case appendPCM
    case syncSource
    case closeSource
    case writeManifest
    case replaceManifest
    case syncDirectory
}

struct RecordingJournalPersistenceFailure: Error, Equatable {
    let reason: RecordingInterruptionReason
    let operation: RecordingJournalPersistenceOperation
    let detail: String

    static func knownPersistenceFailure(
        _ error: Error,
        operation: RecordingJournalPersistenceOperation
    ) -> RecordingJournalPersistenceFailure {
        RecordingJournalPersistenceFailure(
            reason: classifiedReason(in: error) ?? .journalIOFailure,
            operation: operation,
            detail: error.localizedDescription
        )
    }

    static func classifyIfPersistenceFailure(
        _ error: Error,
        operation: RecordingJournalPersistenceOperation
    ) -> RecordingJournalPersistenceFailure? {
        if isInvariantFailure(error) {
            return nil
        }
        guard isFilePersistenceFailure(error) else {
            return nil
        }
        return RecordingJournalPersistenceFailure(
            reason: classifiedReason(in: error) ?? .journalIOFailure,
            operation: operation,
            detail: error.localizedDescription
        )
    }

    private static func isFilePersistenceFailure(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.userInfo[NSUnderlyingErrorKey] is Error {
            return true
        }
        if case RecordingJournalStoreError.systemCall = error {
            return true
        }
        return nsError.domain == NSPOSIXErrorDomain
            || nsError.domain == NSCocoaErrorDomain
    }

    private static func classifiedReason(in error: Error) -> RecordingInterruptionReason? {
        let nsError = error as NSError
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error,
           let reason = classifiedReason(in: underlying) {
            return reason
        }

        if case let RecordingJournalStoreError.systemCall(_, code) = error {
            return posixReason(code)
        }
        if nsError.domain == NSPOSIXErrorDomain {
            return posixReason(Int32(nsError.code))
        }
        if nsError.domain == NSCocoaErrorDomain {
            switch CocoaError.Code(rawValue: nsError.code) {
            case .fileWriteOutOfSpace:
                return .storageFull
            case .fileWriteNoPermission, .fileWriteVolumeReadOnly:
                return .permissionDenied
            default:
                return nil
            }
        }
        return nil
    }

    private static func posixReason(_ code: Int32) -> RecordingInterruptionReason? {
        switch code {
        case ENOSPC, EDQUOT:
            return .storageFull
        case EACCES, EPERM, EROFS:
            return .permissionDenied
        default:
            return nil
        }
    }

    private static func isInvariantFailure(_ error: Error) -> Bool {
        if error is RecordingJournalError {
            return true
        }
        if let writerError = error as? RecordingPCMJournalWriterError {
            switch writerError {
            case .conflictingFrameOffset, .oddByteChunk, .writerClosed:
                return true
            case .writeFailed:
                return false
            }
        }
        if let storeError = error as? RecordingJournalStoreError {
            switch storeError {
            case .systemCall:
                return false
            default:
                return true
            }
        }
        return false
    }
}
