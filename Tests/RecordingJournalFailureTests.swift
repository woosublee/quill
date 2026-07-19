import Darwin
import Foundation

@main
struct RecordingJournalFailureTests {
    static func main() {
        do {
            try classifiesKnownPOSIXAndCocoaFailures()
            try classifiesNestedUnderlyingFailureBeforeOuterFallback()
            try defaultsKnownPersistenceBoundaryToJournalIOFailure()
            try classifiesGenericFilePersistenceFailuresAsJournalIOFailure()
            try excludesJournalInvariantFailures()
            print("RecordingJournalFailureTests passed")
        } catch {
            fputs("RecordingJournalFailureTests failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func classifiesKnownPOSIXAndCocoaFailures() throws {
        let cases: [(Error, RecordingInterruptionReason)] = [
            (NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)), .storageFull),
            (NSError(domain: NSPOSIXErrorDomain, code: Int(EDQUOT)), .storageFull),
            (NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)), .permissionDenied),
            (NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM)), .permissionDenied),
            (NSError(domain: NSPOSIXErrorDomain, code: Int(EROFS)), .permissionDenied),
            (CocoaError(.fileWriteOutOfSpace), .storageFull),
            (CocoaError(.fileWriteNoPermission), .permissionDenied),
            (CocoaError(.fileWriteVolumeReadOnly), .permissionDenied)
        ]

        for (error, expectedReason) in cases {
            let failure = RecordingJournalPersistenceFailure.knownPersistenceFailure(
                error,
                operation: .appendPCM
            )
            try expectEqual(failure.reason, expectedReason, "known failure reason")
            try expectEqual(failure.operation, .appendPCM, "known failure operation")
        }
    }

    private static func classifiesNestedUnderlyingFailureBeforeOuterFallback() throws {
        let nested = NSError(
            domain: NSCocoaErrorDomain,
            code: CocoaError.fileWriteUnknown.rawValue,
            userInfo: [NSUnderlyingErrorKey: NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(ENOSPC)
            )]
        )

        let failure = RecordingJournalPersistenceFailure.knownPersistenceFailure(
            nested,
            operation: .writeManifest
        )

        try expectEqual(failure.reason, .storageFull, "nested failure reason")
        try expectEqual(failure.operation, .writeManifest, "nested failure operation")
    }

    private static func defaultsKnownPersistenceBoundaryToJournalIOFailure() throws {
        let unknown = TestFailure("injected persistence failure")
        let failure = RecordingJournalPersistenceFailure.knownPersistenceFailure(
            unknown,
            operation: .syncDirectory
        )

        try expectEqual(failure.reason, .journalIOFailure, "unknown persistence reason")
        try expectEqual(failure.operation, .syncDirectory, "unknown persistence operation")
        guard !failure.detail.isEmpty else {
            throw TestFailure("failure detail must not be empty")
        }
    }

    private static func classifiesGenericFilePersistenceFailuresAsJournalIOFailure() throws {
        let cases: [Error] = [
            NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)),
            RecordingJournalStoreError.systemCall("fsync", EIO),
            CocoaError(.fileWriteUnknown)
        ]

        for error in cases {
            let failure = RecordingJournalPersistenceFailure.classifyIfPersistenceFailure(
                error,
                operation: .writeManifest
            )
            try expectEqual(
                failure?.reason,
                .journalIOFailure,
                "generic file persistence reason"
            )
            try expectEqual(
                failure?.operation,
                .writeManifest,
                "generic file persistence operation"
            )
        }
        try expectEqual(
            RecordingJournalPersistenceFailure.classifyIfPersistenceFailure(
                TestFailure("unrelated runtime error"),
                operation: .writeManifest
            ),
            nil,
            "unknown non-file error"
        )
    }

    private static func excludesJournalInvariantFailures() throws {
        let invariantErrors: [Error] = [
            RecordingPCMJournalWriterError.oddByteChunk,
            RecordingPCMJournalWriterError.conflictingFrameOffset,
            RecordingJournalStoreError.checkpointRegression,
            RecordingJournalError.invalidManifest("broken")
        ]

        for error in invariantErrors {
            let failure = RecordingJournalPersistenceFailure.classifyIfPersistenceFailure(
                error,
                operation: .writeManifest
            )
            try expectEqual(failure, nil, "invariant failure classification")
        }
    }

    private static func expectEqual<T: Equatable>(
        _ actual: T,
        _ expected: T,
        _ label: String
    ) throws {
        guard actual == expected else {
            throw TestFailure("\(label): expected \(expected), got \(actual)")
        }
    }

    private struct TestFailure: Error, CustomStringConvertible {
        let description: String

        init(_ description: String) {
            self.description = description
        }
    }
}
