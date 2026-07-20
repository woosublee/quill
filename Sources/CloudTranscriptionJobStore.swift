import Darwin
import Foundation

enum CloudTranscriptionJobPhase: String, Codable, Equatable, Sendable {
    case prepared
    case transcribing
    case interrupted
    case failed
    case assembled
}

struct CloudTranscriptionCompletedChunk: Codable, Equatable, Sendable {
    let index: Int
    let normalizedRawText: String
}

struct CloudTranscriptionStoredFailure: Codable, Equatable, Sendable {
    let category: CloudTranscriptionFailureCategory
    let httpStatus: Int?
    let retryAfterSeconds: TimeInterval?
}

struct CloudTranscriptionCompletionPolicy: Codable, Equatable, Sendable {
    let postProcessingEnabled: Bool
    let preserveExactWording: Bool
    let outputLanguage: String
    let pressEnterCommandEnabled: Bool
}

enum CloudTranscriptionJobValidationError: Error, Equatable {
    case unsupportedSchemaVersion(Int)
    case historyIDMismatch
    case unsafeAudioFileName
    case invalidSourceIdentity
    case sourcePlanMismatch
    case identityPlanMismatch
    case invalidPlan
    case invalidCompletedChunkPrefix
    case firstIncompleteChunkIndexMismatch
    case assembledBeforeComplete
}

struct CloudTranscriptionJobRecord: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let historyID: UUID
    let createdAt: Date
    var updatedAt: Date
    var phase: CloudTranscriptionJobPhase
    let identity: CloudTranscriptionJobIdentity
    let plan: CloudTranscriptionChunkPlan
    var completedChunks: [CloudTranscriptionCompletedChunk]
    var firstIncompleteChunkIndex: Int
    var lastFailure: CloudTranscriptionStoredFailure?
    let completionPolicy: CloudTranscriptionCompletionPolicy

    func validate(fileNameID: UUID) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw CloudTranscriptionJobValidationError.unsupportedSchemaVersion(
                schemaVersion
            )
        }
        guard historyID == fileNameID else {
            throw CloudTranscriptionJobValidationError.historyIDMismatch
        }
        guard Self.isSafeBasename(identity.source.audioFileName) else {
            throw CloudTranscriptionJobValidationError.unsafeAudioFileName
        }
        guard identity.source.frameCount > 0,
              identity.source.dataByteCount
                == identity.source.frameCount
                    * UInt64(CanonicalPCM16WAV.bytesPerFrame),
              identity.source.physicalByteCount
                == CanonicalPCM16WAV.headerByteCount
                    + identity.source.dataByteCount,
              identity.source.sha256.count == 64 else {
            throw CloudTranscriptionJobValidationError.invalidSourceIdentity
        }
        guard identity.source.frameCount == plan.sourceFrameCount else {
            throw CloudTranscriptionJobValidationError.sourcePlanMismatch
        }
        guard identity.planID == plan.planID else {
            throw CloudTranscriptionJobValidationError.identityPlanMismatch
        }
        do {
            try plan.validate()
        } catch {
            throw CloudTranscriptionJobValidationError.invalidPlan
        }
        guard completedChunks.count <= plan.chunks.count,
              completedChunks.enumerated().allSatisfy({ offset, chunk in
                  chunk.index == offset
              }) else {
            throw CloudTranscriptionJobValidationError.invalidCompletedChunkPrefix
        }
        guard firstIncompleteChunkIndex == completedChunks.count else {
            throw CloudTranscriptionJobValidationError
                .firstIncompleteChunkIndexMismatch
        }
        if phase == .assembled,
           completedChunks.count != plan.chunks.count {
            throw CloudTranscriptionJobValidationError.assembledBeforeComplete
        }
    }

    private static func isSafeBasename(_ value: String) -> Bool {
        guard !value.isEmpty,
              value != ".",
              value != "..",
              !value.hasPrefix("/"),
              !value.contains("/"),
              !value.contains("\\") else {
            return false
        }
        return URL(fileURLWithPath: value).lastPathComponent == value
    }
}

struct CloudTranscriptionJobSession: Hashable, Sendable {
    let historyID: UUID
    let token: UUID
}

struct CloudTranscriptionReconciliation: Equatable, Sendable {
    let resumable: [CloudTranscriptionJobRecord]
    let waitingForRetry: [CloudTranscriptionJobRecord]
    let invalid: [UUID]
}

enum CloudTranscriptionJobStoreError: Error, Equatable {
    case staleSession
    case jobNotFound
    case identityMismatch
    case checkpointRegression
    case systemCall(String, Int32)
}

struct CloudTranscriptionAtomicWriteOperations {
    let openTemporary: (URL) throws -> Int32
    let writeAll: (Data, Int32) throws -> Void
    let syncFile: (Int32) throws -> Void
    let closeFile: (Int32) throws -> Void
    let replace: (URL, URL) throws -> Void
    let syncDirectory: (URL) throws -> Void

    static let live = CloudTranscriptionAtomicWriteOperations(
        openTemporary: { url in
            let descriptor = Darwin.open(
                url.path,
                O_WRONLY | O_CREAT | O_EXCL,
                mode_t(0o600)
            )
            guard descriptor >= 0 else {
                throw CloudTranscriptionJobStoreError.systemCall(
                    "open cloud transcription sidecar temp",
                    errno
                )
            }
            return descriptor
        },
        writeAll: { data, descriptor in
            try data.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                var offset = 0
                while offset < rawBuffer.count {
                    let written = Darwin.write(
                        descriptor,
                        baseAddress.advanced(by: offset),
                        rawBuffer.count - offset
                    )
                    guard written >= 0 else {
                        if errno == EINTR { continue }
                        throw CloudTranscriptionJobStoreError.systemCall(
                            "write cloud transcription sidecar",
                            errno
                        )
                    }
                    guard written > 0 else {
                        throw CloudTranscriptionJobStoreError.systemCall(
                            "write cloud transcription sidecar zero bytes",
                            EIO
                        )
                    }
                    offset += written
                }
            }
        },
        syncFile: { descriptor in
            if Darwin.fcntl(descriptor, F_FULLFSYNC) == 0 { return }
            let fullSyncError = errno
            guard Darwin.fsync(descriptor) == 0 else {
                throw CloudTranscriptionJobStoreError.systemCall(
                    "F_FULLFSYNC(\(fullSyncError))/fsync cloud transcription sidecar",
                    errno
                )
            }
        },
        closeFile: { descriptor in
            guard Darwin.close(descriptor) == 0 else {
                throw CloudTranscriptionJobStoreError.systemCall(
                    "close cloud transcription sidecar temp",
                    errno
                )
            }
        },
        replace: { temporaryURL, targetURL in
            guard Darwin.rename(temporaryURL.path, targetURL.path) == 0 else {
                throw CloudTranscriptionJobStoreError.systemCall(
                    "rename cloud transcription sidecar",
                    errno
                )
            }
        },
        syncDirectory: { directoryURL in
            let descriptor = Darwin.open(directoryURL.path, O_RDONLY)
            guard descriptor >= 0 else {
                throw CloudTranscriptionJobStoreError.systemCall(
                    "open cloud transcription jobs directory",
                    errno
                )
            }
            defer { Darwin.close(descriptor) }
            if Darwin.fsync(descriptor) != 0, errno != EINVAL {
                throw CloudTranscriptionJobStoreError.systemCall(
                    "fsync cloud transcription jobs directory",
                    errno
                )
            }
        }
    )
}

final class CloudTranscriptionJobStore: @unchecked Sendable {
    let jobsDirectory: URL
    let temporaryRoot: URL

    private let now: @Sendable () -> Date
    private let fileManager: FileManager
    private let atomicWriteOperations: CloudTranscriptionAtomicWriteOperations
    private let lock = NSLock()
    private var activeTokens: [UUID: UUID] = [:]

    init(
        jobsDirectory: URL,
        temporaryRoot: URL,
        now: @escaping @Sendable () -> Date = { Date() },
        fileManager: FileManager = .default,
        atomicWriteOperations: CloudTranscriptionAtomicWriteOperations = .live
    ) {
        self.jobsDirectory = jobsDirectory
        self.temporaryRoot = temporaryRoot
        self.now = now
        self.fileManager = fileManager
        self.atomicWriteOperations = atomicWriteOperations
    }

    func beginSession(historyID: UUID) -> CloudTranscriptionJobSession {
        lock.withCloudTranscriptionJobLock {
            let session = CloudTranscriptionJobSession(
                historyID: historyID,
                token: UUID()
            )
            activeTokens[historyID] = session.token
            return session
        }
    }

    func invalidateSession(historyID: UUID) {
        lock.withCloudTranscriptionJobLock {
            _ = activeTokens.removeValue(forKey: historyID)
        }
    }

    func create(
        _ record: CloudTranscriptionJobRecord,
        session: CloudTranscriptionJobSession
    ) throws {
        try lock.withCloudTranscriptionJobLock {
            try requireActiveSession(session, historyID: record.historyID)
            try record.validate(fileNameID: record.historyID)
            try ensureJobsDirectory()
            try write(record)
        }
    }

    func load(historyID: UUID) throws -> CloudTranscriptionJobRecord? {
        try lock.withCloudTranscriptionJobLock {
            try loadUnlocked(historyID: historyID)
        }
    }

    func update(
        _ record: CloudTranscriptionJobRecord,
        session: CloudTranscriptionJobSession
    ) throws {
        try lock.withCloudTranscriptionJobLock {
            try requireActiveSession(session, historyID: record.historyID)
            guard fileManager.fileExists(
                atPath: recordURL(historyID: record.historyID).path
            ) else {
                throw CloudTranscriptionJobStoreError.jobNotFound
            }
            var updated = record
            updated.updatedAt = now()
            try updated.validate(fileNameID: updated.historyID)
            try write(updated)
        }
    }

    func delete(
        historyID: UUID,
        session: CloudTranscriptionJobSession?
    ) throws {
        try lock.withCloudTranscriptionJobLock {
            if let session {
                try requireActiveSession(session, historyID: historyID)
            }
            let url = recordURL(historyID: historyID)
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
                try atomicWriteOperations.syncDirectory(jobsDirectory)
            }
            activeTokens.removeValue(forKey: historyID)
        }
    }

    func checkpointStore(
        session: CloudTranscriptionJobSession
    ) -> any CloudTranscriptionCheckpointStore {
        CloudTranscriptionJobCheckpointAdapter(store: self, session: session)
    }

    func checkpointStore(
        session: CloudTranscriptionJobSession,
        completionPolicy: CloudTranscriptionCompletionPolicy
    ) -> any CloudTranscriptionCheckpointStore {
        CloudTranscriptionPreparingCheckpointAdapter(
            store: self,
            session: session,
            completionPolicy: completionPolicy
        )
    }

    func deleteCompletedJob(
        historyID: UUID,
        session: CloudTranscriptionJobSession
    ) throws {
        try delete(historyID: historyID, session: session)
    }

    func replaceForIncompatibleRetry(
        historyID: UUID,
        oldSession: CloudTranscriptionJobSession,
        newSession: CloudTranscriptionJobSession
    ) throws {
        try lock.withCloudTranscriptionJobLock {
            guard oldSession != newSession,
                  oldSession.historyID == historyID,
                  newSession.historyID == historyID,
                  activeTokens[historyID] == newSession.token else {
                throw CloudTranscriptionJobStoreError.staleSession
            }
            let url = recordURL(historyID: historyID)
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
                try atomicWriteOperations.syncDirectory(jobsDirectory)
            }
        }
    }

    func reconcile(
        history: [PipelineHistoryItem],
        audioRoot: URL
    ) -> CloudTranscriptionReconciliation {
        lock.withCloudTranscriptionJobLock {
            let historyByID = Dictionary(uniqueKeysWithValues: history.map {
                ($0.id, $0)
            })
            var resumable: [CloudTranscriptionJobRecord] = []
            var waitingForRetry: [CloudTranscriptionJobRecord] = []
            var invalid: [UUID] = []
            let urls = (try? fileManager.contentsOfDirectory(
                at: jobsDirectory,
                includingPropertiesForKeys: nil
            )) ?? []

            for url in urls where url.pathExtension == "json" {
                guard let historyID = UUID(
                    uuidString: url.deletingPathExtension().lastPathComponent
                ) else {
                    continue
                }
                do {
                    guard let record = try loadUnlocked(historyID: historyID),
                          let historyItem = historyByID[historyID],
                          historyItem.audioFileName
                            == record.identity.source.audioFileName else {
                        invalid.append(historyID)
                        continue
                    }
                    let audioURL = audioRoot.appendingPathComponent(
                        record.identity.source.audioFileName,
                        isDirectory: false
                    )
                    let layout = try CanonicalPCM16WAV.validateFile(at: audioURL)
                    let source = try CloudTranscriptionSourceIdentityBuilder.make(
                        fileURL: audioURL,
                        layout: layout
                    )
                    guard source == record.identity.source else {
                        invalid.append(historyID)
                        continue
                    }
                    switch record.phase {
                    case .transcribing, .interrupted:
                        resumable.append(record)
                    case .prepared, .failed, .assembled:
                        waitingForRetry.append(record)
                    }
                } catch {
                    invalid.append(historyID)
                }
            }

            return CloudTranscriptionReconciliation(
                resumable: resumable.sorted { $0.createdAt < $1.createdAt },
                waitingForRetry: waitingForRetry.sorted {
                    $0.createdAt < $1.createdAt
                },
                invalid: invalid.sorted { $0.uuidString < $1.uuidString }
            )
        }
    }

    func removeStaleTemporaryArtifacts() throws {
        try lock.withCloudTranscriptionJobLock {
            guard fileManager.fileExists(atPath: temporaryRoot.path) else {
                return
            }
            for url in try fileManager.contentsOfDirectory(
                at: temporaryRoot,
                includingPropertiesForKeys: nil
            ) {
                try fileManager.removeItem(at: url)
            }
        }
    }

    fileprivate func prepareIfNeeded(
        identity: CloudTranscriptionJobIdentity,
        plan: CloudTranscriptionChunkPlan,
        completionPolicy: CloudTranscriptionCompletionPolicy,
        session: CloudTranscriptionJobSession
    ) throws {
        try lock.withCloudTranscriptionJobLock {
            try requireActiveSession(session, historyID: session.historyID)
            if let record = try loadUnlocked(historyID: session.historyID) {
                guard record.identity == identity,
                      record.plan == plan,
                      record.completionPolicy == completionPolicy else {
                    throw CloudTranscriptionJobStoreError.identityMismatch
                }
                return
            }
            try ensureJobsDirectory()
            let timestamp = now()
            let record = CloudTranscriptionJobRecord(
                schemaVersion: CloudTranscriptionJobRecord.currentSchemaVersion,
                historyID: session.historyID,
                createdAt: timestamp,
                updatedAt: timestamp,
                phase: .transcribing,
                identity: identity,
                plan: plan,
                completedChunks: [],
                firstIncompleteChunkIndex: 0,
                lastFailure: nil,
                completionPolicy: completionPolicy
            )
            try record.validate(fileNameID: record.historyID)
            try write(record)
        }
    }

    fileprivate func loadCompatible(
        identity: CloudTranscriptionJobIdentity,
        session: CloudTranscriptionJobSession
    ) throws -> CloudTranscriptionCheckpoint? {
        try lock.withCloudTranscriptionJobLock {
            try requireActiveSession(session, historyID: session.historyID)
            guard let record = try loadUnlocked(historyID: session.historyID),
                  record.identity == identity else {
                return nil
            }
            return CloudTranscriptionCheckpoint(
                identity: record.identity,
                completedRawTranscripts: record.completedChunks.map(
                    \.normalizedRawText
                )
            )
        }
    }

    fileprivate func save(
        _ checkpoint: CloudTranscriptionCheckpoint,
        session: CloudTranscriptionJobSession
    ) throws {
        try lock.withCloudTranscriptionJobLock {
            try requireActiveSession(session, historyID: session.historyID)
            guard var record = try loadUnlocked(historyID: session.historyID) else {
                throw CloudTranscriptionJobStoreError.jobNotFound
            }
            guard record.identity == checkpoint.identity else {
                throw CloudTranscriptionJobStoreError.identityMismatch
            }
            let normalizedTranscripts = checkpoint.completedRawTranscripts.map(
                Self.normalizedText
            )
            guard normalizedTranscripts.count >= record.completedChunks.count,
                  normalizedTranscripts.count <= record.plan.chunks.count,
                  Array(normalizedTranscripts.prefix(record.completedChunks.count))
                    == record.completedChunks.map(\.normalizedRawText) else {
                throw CloudTranscriptionJobStoreError.checkpointRegression
            }
            record.completedChunks = normalizedTranscripts.enumerated().map {
                CloudTranscriptionCompletedChunk(
                    index: $0.offset,
                    normalizedRawText: $0.element
                )
            }
            record.firstIncompleteChunkIndex = normalizedTranscripts.count
            record.phase = normalizedTranscripts.count == record.plan.chunks.count
                ? .assembled
                : .transcribing
            record.lastFailure = nil
            record.updatedAt = now()
            try record.validate(fileNameID: record.historyID)
            try write(record)
        }
    }

    fileprivate func recordFailure(
        category: CloudTranscriptionFailureCategory,
        session: CloudTranscriptionJobSession
    ) throws {
        try lock.withCloudTranscriptionJobLock {
            try requireActiveSession(session, historyID: session.historyID)
            guard var record = try loadUnlocked(historyID: session.historyID) else {
                throw CloudTranscriptionJobStoreError.jobNotFound
            }
            record.phase = category == .cancelled ? .interrupted : .failed
            record.lastFailure = CloudTranscriptionStoredFailure(
                category: category,
                httpStatus: nil,
                retryAfterSeconds: nil
            )
            record.updatedAt = now()
            try record.validate(fileNameID: record.historyID)
            try write(record)
        }
    }

    private func requireActiveSession(
        _ session: CloudTranscriptionJobSession,
        historyID: UUID
    ) throws {
        guard session.historyID == historyID,
              activeTokens[historyID] == session.token else {
            throw CloudTranscriptionJobStoreError.staleSession
        }
    }

    private func ensureJobsDirectory() throws {
        if !fileManager.fileExists(atPath: jobsDirectory.path) {
            try fileManager.createDirectory(
                at: jobsDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
    }

    private func recordURL(historyID: UUID) -> URL {
        jobsDirectory.appendingPathComponent(
            "\(historyID.uuidString).json",
            isDirectory: false
        )
    }

    private func loadUnlocked(
        historyID: UUID
    ) throws -> CloudTranscriptionJobRecord? {
        let url = recordURL(historyID: historyID)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let record = try JSONDecoder().decode(
            CloudTranscriptionJobRecord.self,
            from: data
        )
        try record.validate(fileNameID: historyID)
        return record
    }

    private func write(_ record: CloudTranscriptionJobRecord) throws {
        try ensureJobsDirectory()
        let data = try JSONEncoder().encode(record)
        let targetURL = recordURL(historyID: record.historyID)
        let temporaryURL = jobsDirectory.appendingPathComponent(
            ".\(record.historyID.uuidString).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        let descriptor = try atomicWriteOperations.openTemporary(temporaryURL)
        var descriptorOpen = true
        defer {
            if descriptorOpen { Darwin.close(descriptor) }
            try? fileManager.removeItem(at: temporaryURL)
        }
        try atomicWriteOperations.writeAll(data, descriptor)
        try atomicWriteOperations.syncFile(descriptor)
        try atomicWriteOperations.closeFile(descriptor)
        descriptorOpen = false
        try atomicWriteOperations.replace(temporaryURL, targetURL)
        try atomicWriteOperations.syncDirectory(jobsDirectory)
    }

    private static func normalizedText(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

private struct CloudTranscriptionPreparingCheckpointAdapter:
    CloudTranscriptionCheckpointStore,
    CloudTranscriptionCheckpointPreparing,
    Sendable {
    let store: CloudTranscriptionJobStore
    let session: CloudTranscriptionJobSession
    let completionPolicy: CloudTranscriptionCompletionPolicy

    func prepare(
        identity: CloudTranscriptionJobIdentity,
        plan: CloudTranscriptionChunkPlan
    ) async throws {
        try store.prepareIfNeeded(
            identity: identity,
            plan: plan,
            completionPolicy: completionPolicy,
            session: session
        )
    }

    func loadCompatible(
        identity: CloudTranscriptionJobIdentity
    ) async throws -> CloudTranscriptionCheckpoint? {
        try store.loadCompatible(identity: identity, session: session)
    }

    func save(_ checkpoint: CloudTranscriptionCheckpoint) async throws {
        try store.save(checkpoint, session: session)
    }

    func recordFailure(
        category: CloudTranscriptionFailureCategory
    ) async throws {
        try store.recordFailure(category: category, session: session)
    }
}

private struct CloudTranscriptionJobCheckpointAdapter:
    CloudTranscriptionCheckpointStore,
    Sendable {
    let store: CloudTranscriptionJobStore
    let session: CloudTranscriptionJobSession

    func loadCompatible(
        identity: CloudTranscriptionJobIdentity
    ) async throws -> CloudTranscriptionCheckpoint? {
        try store.loadCompatible(identity: identity, session: session)
    }

    func save(_ checkpoint: CloudTranscriptionCheckpoint) async throws {
        try store.save(checkpoint, session: session)
    }

    func recordFailure(
        category: CloudTranscriptionFailureCategory
    ) async throws {
        try store.recordFailure(category: category, session: session)
    }
}

private extension NSLock {
    func withCloudTranscriptionJobLock<T>(
        _ body: () throws -> T
    ) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
