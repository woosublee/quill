import Darwin
import Foundation

private enum HistoryRecoveryLayout {
    static let recoveryDirectoryName = "Recovery"
    static let stateDirectoryName = ".recovery-state"
    static let scratchDirectoryName = ".scratch"
    static let snapshotPrefix = "history-"
}

enum HistoryRecoverySnapshotIntegrity: String, Codable, Equatable, Sendable {
    case ready
    case invalid
}

enum HistoryRecoverySnapshotStatus: String, Codable, Equatable, Sendable {
    case available
    case partial
    case completed
    case inspectionFailed
}

enum HistoryRecoveryRecordStatus: String, Codable, Equatable, Sendable {
    case planned
    case imported
    case alreadyPresent
    case conflict
    case failed
}

struct HistoryRecoveryRecordState: Codable, Equatable, Sendable {
    let id: UUID
    var status: HistoryRecoveryRecordStatus
    var audioFileName: String?
    var transcriptFileName: String?

    init(
        id: UUID,
        status: HistoryRecoveryRecordStatus,
        audioFileName: String? = nil,
        transcriptFileName: String? = nil
    ) {
        self.id = id
        self.status = status
        self.audioFileName = audioFileName
        self.transcriptFileName = transcriptFileName
    }
}

struct HistoryRecoveryImportResult: Equatable, Sendable {
    let snapshotID: UUID
    let importedRecordCount: Int
    let alreadyPresentRecordCount: Int
    let conflictRecordCount: Int
    let failedRecordCount: Int
}

struct HistoryRecoveryInspection: Equatable, Sendable {
    let snapshotID: UUID
    let readableRecordCount: Int
    let alreadyPresentRecordCount: Int
    let conflictRecordCount: Int

    var importableRecordCount: Int {
        readableRecordCount - alreadyPresentRecordCount - conflictRecordCount
    }
}

struct HistoryRecoveryState: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let snapshotID: UUID
    var status: HistoryRecoverySnapshotStatus
    var records: [HistoryRecoveryRecordState]
    var completedAt: Date?
    var automaticDeletionCancelledAt: Date?
    var statusBeforeInspectionFailure: HistoryRecoverySnapshotStatus?

    init(
        snapshotID: UUID,
        status: HistoryRecoverySnapshotStatus,
        records: [HistoryRecoveryRecordState] = [],
        completedAt: Date?,
        automaticDeletionCancelledAt: Date? = nil,
        statusBeforeInspectionFailure: HistoryRecoverySnapshotStatus? = nil
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.snapshotID = snapshotID
        self.status = status
        self.records = records
        self.completedAt = completedAt
        self.automaticDeletionCancelledAt = automaticDeletionCancelledAt
        self.statusBeforeInspectionFailure = statusBeforeInspectionFailure
    }

    var scheduledDeletionAt: Date? {
        guard status == .completed,
              automaticDeletionCancelledAt == nil,
              let completedAt else {
            return nil
        }
        return completedAt.addingTimeInterval(7 * 24 * 60 * 60)
    }
}

struct HistoryRecoverySnapshotDescriptor: Identifiable, Equatable, Sendable {
    let snapshot: HistoryArchiveSnapshot
    let snapshotURL: URL
    let payloadByteCount: UInt64
    let integrity: HistoryRecoverySnapshotIntegrity
    let state: HistoryRecoveryState?

    var id: UUID { snapshot.id }

    var status: HistoryRecoverySnapshotStatus {
        state?.status ?? .available
    }

    var scheduledDeletionAt: Date? {
        state?.scheduledDeletionAt
    }
}

enum HistoryRecoveryServiceError: Error, LocalizedError {
    case snapshotNotFound
    case snapshotNotReady
    case invalidState
    case metadataWriteFailed

    var errorDescription: String? {
        switch self {
        case .snapshotNotFound:
            return "The recovery snapshot could not be found."
        case .snapshotNotReady:
            return "The recovery snapshot is not ready."
        case .invalidState:
            return "The recovery state is invalid."
        case .metadataWriteFailed:
            return "The recovery state could not be saved."
        }
    }
}

enum HistoryRecoveryDurability {
    static func writeAll(
        _ data: Data,
        write: (UnsafePointer<UInt8>, Int) -> (written: Int, errorCode: Int32)
    ) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard var pointer = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return
            }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let outcome = write(pointer, remaining)
                if outcome.written > 0 {
                    guard outcome.written <= remaining else {
                        throw HistoryRecoveryServiceError.metadataWriteFailed
                    }
                    remaining -= outcome.written
                    pointer = pointer.advanced(by: outcome.written)
                    continue
                }
                guard outcome.errorCode == EINTR || outcome.errorCode == EAGAIN else {
                    throw HistoryRecoveryServiceError.metadataWriteFailed
                }
            }
        }
    }
}

final class HistoryRecoveryService {
    private let storageRoot: URL
    private let fileManager: FileManager
    private let now: () -> Date

    init(
        storageRoot: URL,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.storageRoot = storageRoot.standardizedFileURL
        self.fileManager = fileManager
        self.now = now
    }

    func listSnapshots() -> [HistoryRecoverySnapshotDescriptor] {
        let recoveryDirectory = recoveryDirectoryURL
        guard fileManager.fileExists(atPath: recoveryDirectory.path),
              let entries = try? fileManager.contentsOfDirectory(
                at: recoveryDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        return entries.compactMap { snapshotURL in
            let values = try? snapshotURL.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard snapshotURL.lastPathComponent.hasPrefix(HistoryRecoveryLayout.snapshotPrefix),
                  values?.isDirectory == true || values?.isSymbolicLink == true,
                  let snapshotID = snapshotID(from: snapshotURL) else {
                return nil
            }
            guard let snapshot = try? JSONDecoder().decode(
                HistoryArchiveSnapshot.self,
                from: Data(contentsOf: snapshotURL.appendingPathComponent("manifest.json"))
            ) else {
                return HistoryRecoverySnapshotDescriptor(
                    snapshot: invalidSnapshot(id: snapshotID, at: snapshotURL),
                    snapshotURL: snapshotURL,
                    payloadByteCount: 0,
                    integrity: .invalid,
                    state: loadState(for: snapshotID)
                )
            }
            let integrity = validate(snapshot: snapshot, at: snapshotURL)
                ? HistoryRecoverySnapshotIntegrity.ready
                : .invalid
            return HistoryRecoverySnapshotDescriptor(
                snapshot: snapshot,
                snapshotURL: snapshotURL,
                payloadByteCount: payloadByteCount(for: snapshot),
                integrity: integrity,
                state: loadState(for: snapshot.id)
            )
        }
        .sorted { lhs, rhs in
            if lhs.snapshot.archivedAt != rhs.snapshot.archivedAt {
                return lhs.snapshot.archivedAt > rhs.snapshot.archivedAt
            }
            return lhs.snapshot.id.uuidString < rhs.snapshot.id.uuidString
        }
    }

    private func snapshotID(from snapshotURL: URL) -> UUID? {
        let name = snapshotURL.lastPathComponent
        guard name.count >= 36 else { return nil }
        return UUID(uuidString: String(name.suffix(36)))
    }

    private func invalidSnapshot(id: UUID, at snapshotURL: URL) -> HistoryArchiveSnapshot {
        let archivedAt = (try? snapshotURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
        return HistoryArchiveSnapshot(
            schemaVersion: 0,
            id: id,
            archivedAt: archivedAt,
            components: []
        )
    }

    func stateURL(for snapshotID: UUID) -> URL {
        recoveryDirectoryURL
            .appendingPathComponent(HistoryRecoveryLayout.stateDirectoryName, isDirectory: true)
            .appendingPathComponent(snapshotID.uuidString.lowercased() + ".json")
    }

    func saveState(_ state: HistoryRecoveryState) throws {
        guard state.schemaVersion == HistoryRecoveryState.currentSchemaVersion else {
            throw HistoryRecoveryServiceError.invalidState
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try writeDurably(
            encoder.encode(state),
            to: stateURL(for: state.snapshotID)
        )
    }

    func inspectSnapshot(
        id snapshotID: UUID,
        against activeHistory: [PipelineHistoryItem]
    ) throws -> HistoryRecoveryInspection {
        guard let descriptor = listSnapshots().first(where: { $0.id == snapshotID }) else {
            throw HistoryRecoveryServiceError.snapshotNotFound
        }
        guard descriptor.integrity == .ready else {
            throw HistoryRecoveryServiceError.snapshotNotReady
        }
        let activeItems = Dictionary(uniqueKeysWithValues: activeHistory.map { ($0.id, $0) })
        let sourceItems: [PipelineHistoryItem]
        do {
            sourceItems = try loadSourceHistory(from: descriptor)
        } catch {
            try markInspectionFailed(for: descriptor)
            throw error
        }
        try restoreStatusAfterSuccessfulInspection(for: descriptor)
        var alreadyPresentRecordCount = 0
        var conflictRecordCount = 0
        for sourceItem in sourceItems {
            guard let activeItem = activeItems[sourceItem.id] else { continue }
            if sourceItem.isLogicallyEquivalentForHistoryRecovery(to: activeItem) {
                alreadyPresentRecordCount += 1
            } else {
                conflictRecordCount += 1
            }
        }
        return HistoryRecoveryInspection(
            snapshotID: snapshotID,
            readableRecordCount: sourceItems.count,
            alreadyPresentRecordCount: alreadyPresentRecordCount,
            conflictRecordCount: conflictRecordCount
        )
    }

    func importSnapshot(
        id snapshotID: UUID,
        into activeStore: PipelineHistoryStore,
        audioDirectory: URL,
        transcriptDirectory: URL
    ) throws -> HistoryRecoveryImportResult {
        guard activeStore.availability == .ready,
              activeStore.durability == .durable,
              let descriptor = listSnapshots().first(where: { $0.id == snapshotID }) else {
            throw HistoryRecoveryServiceError.snapshotNotFound
        }
        guard descriptor.integrity == .ready else {
            throw HistoryRecoveryServiceError.snapshotNotReady
        }

        let sourceItems = try loadSourceHistory(from: descriptor)
        var state = descriptor.state ?? HistoryRecoveryState(
            snapshotID: snapshotID,
            status: .available,
            completedAt: nil
        )
        var activeItems = Dictionary(
            uniqueKeysWithValues: activeStore.loadAllHistory().map { ($0.id, $0) }
        )
        var importedRecordCount = 0
        var alreadyPresentRecordCount = 0
        var conflictRecordCount = 0
        var failedRecordCount = 0

        for sourceItem in sourceItems {
            if let activeItem = activeItems[sourceItem.id] {
                if sourceItem.isLogicallyEquivalentForHistoryRecovery(to: activeItem) {
                    updateRecord(
                        id: sourceItem.id,
                        status: .alreadyPresent,
                        audioFileName: activeItem.audioFileName,
                        transcriptFileName: activeItem.transcriptFileName,
                        in: &state
                    )
                    alreadyPresentRecordCount += 1
                } else {
                    updateRecord(id: sourceItem.id, status: .conflict, in: &state)
                    conflictRecordCount += 1
                }
                try saveState(state)
                continue
            }

            do {
                let record = state.records.first(where: { $0.id == sourceItem.id })
                let audioFileName = try prepareAsset(
                    sourceFileName: sourceItem.audioFileName,
                    identifier: .audio,
                    destinationDirectory: audioDirectory,
                    existingDestinationFileName: record?.audioFileName,
                    descriptor: descriptor
                )
                let transcriptFileName = try prepareAsset(
                    sourceFileName: sourceItem.transcriptFileName,
                    identifier: .transcripts,
                    destinationDirectory: transcriptDirectory,
                    existingDestinationFileName: record?.transcriptFileName,
                    descriptor: descriptor
                )
                updateRecord(
                    id: sourceItem.id,
                    status: .planned,
                    audioFileName: audioFileName,
                    transcriptFileName: transcriptFileName,
                    in: &state
                )
                try saveState(state)

                try copyAssetIfNeeded(
                    sourceFileName: sourceItem.audioFileName,
                    destinationFileName: audioFileName,
                    identifier: .audio,
                    destinationDirectory: audioDirectory,
                    descriptor: descriptor
                )
                try copyAssetIfNeeded(
                    sourceFileName: sourceItem.transcriptFileName,
                    destinationFileName: transcriptFileName,
                    identifier: .transcripts,
                    destinationDirectory: transcriptDirectory,
                    descriptor: descriptor
                )

                let importedItem = sourceItem.replacingAssetFileNames(
                    audioFileName: audioFileName,
                    transcriptFileName: transcriptFileName
                )
                _ = try activeStore.upsert(
                    importedItem,
                    maxCount: Int.max,
                    requiresDurableStore: true,
                    keepsImportedDeletion: true
                )
                activeItems[importedItem.id] = importedItem
                updateRecord(
                    id: sourceItem.id,
                    status: .imported,
                    audioFileName: audioFileName,
                    transcriptFileName: transcriptFileName,
                    in: &state
                )
                try saveState(state)
                importedRecordCount += 1
            } catch {
                updateRecord(id: sourceItem.id, status: .failed, in: &state)
                try saveState(state)
                failedRecordCount += 1
            }
        }

        let hasPartialResult = state.records.contains {
            $0.status == .conflict || $0.status == .failed
        }
        state.status = hasPartialResult ? .partial : .completed
        state.completedAt = hasPartialResult ? nil : (state.completedAt ?? now())
        state.statusBeforeInspectionFailure = nil
        try saveState(state)
        return HistoryRecoveryImportResult(
            snapshotID: snapshotID,
            importedRecordCount: importedRecordCount,
            alreadyPresentRecordCount: alreadyPresentRecordCount,
            conflictRecordCount: conflictRecordCount,
            failedRecordCount: failedRecordCount
        )
    }

    func cancelScheduledDeletion(for snapshotID: UUID) throws {
        guard let descriptor = listSnapshots().first(where: { $0.id == snapshotID }),
              descriptor.integrity == .ready,
              var state = descriptor.state,
              state.status == .completed else {
            throw HistoryRecoveryServiceError.invalidState
        }
        state.automaticDeletionCancelledAt = now()
        try saveState(state)
    }

    func deleteSnapshot(id snapshotID: UUID) throws {
        guard let descriptor = listSnapshots().first(where: { $0.id == snapshotID }) else {
            throw HistoryRecoveryServiceError.snapshotNotFound
        }
        try fileManager.removeItem(at: descriptor.snapshotURL)
        try syncDirectory(recoveryDirectoryURL)
        let stateURL = stateURL(for: snapshotID)
        if fileManager.fileExists(atPath: stateURL.path) {
            try fileManager.removeItem(at: stateURL)
            try syncDirectory(stateURL.deletingLastPathComponent())
        }
    }

    @discardableResult
    func removeExpiredCompletedSnapshots() throws -> [UUID] {
        var removed: [UUID] = []
        for descriptor in listSnapshots() {
            guard descriptor.integrity == .ready,
                  descriptor.state?.status == .completed,
                  let deletionAt = descriptor.scheduledDeletionAt,
                  deletionAt <= now() else {
                continue
            }
            try fileManager.removeItem(at: descriptor.snapshotURL)
            try syncDirectory(recoveryDirectoryURL)
            let stateURL = stateURL(for: descriptor.id)
            if fileManager.fileExists(atPath: stateURL.path) {
                try fileManager.removeItem(at: stateURL)
                try syncDirectory(stateURL.deletingLastPathComponent())
            }
            removed.append(descriptor.id)
        }
        return removed
    }

    private func loadSourceHistory(
        from descriptor: HistoryRecoverySnapshotDescriptor
    ) throws -> [PipelineHistoryItem] {
        let scratchDirectory = recoveryDirectoryURL
            .appendingPathComponent(HistoryRecoveryLayout.scratchDirectoryName, isDirectory: true)
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        defer { try? fileManager.removeItem(at: scratchDirectory) }
        try fileManager.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)

        let payloadURL = descriptor.snapshotURL.appendingPathComponent("payload", isDirectory: true)
        for identifier in [
            HistoryArchiveSnapshotComponent.Identifier.sqlite,
            .sqliteWAL,
            .sqliteSHM
        ] {
            guard let component = descriptor.snapshot.components.first(where: {
                $0.identifier == identifier
            }) else {
                continue
            }
            let sourceURL = payloadURL.appendingPathComponent(component.relativePath)
            let destinationURL = scratchDirectory.appendingPathComponent(component.relativePath)
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
        }

        let scratchStoreURL = scratchDirectory.appendingPathComponent("PipelineHistory.sqlite")
        let store = PipelineHistoryStore(storeURL: scratchStoreURL)
        defer { try? store.detachForArchiveVerification() }
        guard store.availability == .ready,
              store.verifyHistoryReadable() else {
            throw HistoryRecoveryServiceError.snapshotNotReady
        }
        let history = store.loadAllHistory()
        guard store.availability == .ready else {
            throw HistoryRecoveryServiceError.snapshotNotReady
        }
        try store.detachForArchiveVerification()
        return history
    }

    private func prepareAsset(
        sourceFileName: String?,
        identifier: HistoryArchiveSnapshotComponent.Identifier,
        destinationDirectory: URL,
        existingDestinationFileName: String?,
        descriptor: HistoryRecoverySnapshotDescriptor
    ) throws -> String? {
        guard let sourceFileName else { return nil }
        let sourceURL = try sourceAssetURL(
            fileName: sourceFileName,
            identifier: identifier,
            descriptor: descriptor
        )
        if let existingDestinationFileName,
           isSafeFileName(existingDestinationFileName) {
            let existingURL = destinationDirectory.appendingPathComponent(existingDestinationFileName)
            if fileManager.fileExists(atPath: existingURL.path),
               !containsSymbolicLink(at: existingURL),
               byteCount(at: existingURL) == byteCount(at: sourceURL) {
                return existingDestinationFileName
            }
        }
        return try reserveDestinationFileName(
            sourceFileName: sourceFileName,
            in: destinationDirectory
        )
    }

    private func copyAssetIfNeeded(
        sourceFileName: String?,
        destinationFileName: String?,
        identifier: HistoryArchiveSnapshotComponent.Identifier,
        destinationDirectory: URL,
        descriptor: HistoryRecoverySnapshotDescriptor
    ) throws {
        guard let sourceFileName else {
            guard destinationFileName == nil else {
                throw HistoryRecoveryServiceError.invalidState
            }
            return
        }
        guard let destinationFileName else {
            throw HistoryRecoveryServiceError.invalidState
        }
        let sourceURL = try sourceAssetURL(
            fileName: sourceFileName,
            identifier: identifier,
            descriptor: descriptor
        )
        let destinationURL = destinationDirectory.appendingPathComponent(destinationFileName)
        let sourceByteCount = byteCount(at: sourceURL)
        if fileManager.fileExists(atPath: destinationURL.path) {
            guard !containsSymbolicLink(at: destinationURL),
                  !isDirectory(destinationURL),
                  byteCount(at: destinationURL) == sourceByteCount else {
                throw HistoryRecoveryServiceError.invalidState
            }
            return
        }

        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let temporaryURL = destinationDirectory.appendingPathComponent(
            ".\(destinationFileName).\(UUID().uuidString).tmp"
        )
        defer { try? fileManager.removeItem(at: temporaryURL) }
        try fileManager.copyItem(at: sourceURL, to: temporaryURL)
        guard byteCount(at: temporaryURL) == sourceByteCount else {
            throw HistoryRecoveryServiceError.invalidState
        }
        try syncFile(at: temporaryURL)
        guard Darwin.rename(temporaryURL.path, destinationURL.path) == 0 else {
            throw HistoryRecoveryServiceError.metadataWriteFailed
        }
        try syncDirectory(destinationDirectory)
    }

    private func sourceAssetURL(
        fileName: String,
        identifier: HistoryArchiveSnapshotComponent.Identifier,
        descriptor: HistoryRecoverySnapshotDescriptor
    ) throws -> URL {
        guard isSafeFileName(fileName),
              descriptor.snapshot.components.contains(where: { $0.identifier == identifier }) else {
            throw HistoryRecoveryServiceError.snapshotNotReady
        }
        let directoryName = identifier == .audio ? "audio" : "transcripts"
        let payloadURL = descriptor.snapshotURL.appendingPathComponent("payload", isDirectory: true)
        let sourceURL = payloadURL
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(fileName)
        guard sourceURL.standardizedFileURL.deletingLastPathComponent()
            == payloadURL.appendingPathComponent(directoryName, isDirectory: true).standardizedFileURL,
              fileManager.fileExists(atPath: sourceURL.path),
              !isDirectory(sourceURL),
              !containsSymbolicLink(at: sourceURL) else {
            throw HistoryRecoveryServiceError.snapshotNotReady
        }
        return sourceURL
    }

    private func reserveDestinationFileName(
        sourceFileName: String,
        in directory: URL
    ) throws -> String {
        guard isSafeFileName(sourceFileName) else {
            throw HistoryRecoveryServiceError.snapshotNotReady
        }
        let pathExtension = URL(fileURLWithPath: sourceFileName).pathExtension
        while true {
            let fileName = UUID().uuidString.lowercased()
                + (pathExtension.isEmpty ? "" : ".\(pathExtension)")
            let candidate = directory.appendingPathComponent(fileName)
            if !fileManager.fileExists(atPath: candidate.path) {
                return fileName
            }
        }
    }

    private func isSafeFileName(_ fileName: String) -> Bool {
        guard !fileName.isEmpty,
              fileName != ".",
              fileName != "..",
              !fileName.contains("/"),
              !fileName.contains("\\") else {
            return false
        }
        return URL(fileURLWithPath: fileName).lastPathComponent == fileName
    }

    private func updateRecord(
        id: UUID,
        status: HistoryRecoveryRecordStatus,
        audioFileName: String? = nil,
        transcriptFileName: String? = nil,
        in state: inout HistoryRecoveryState
    ) {
        if let index = state.records.firstIndex(where: { $0.id == id }) {
            state.records[index].status = status
            if let audioFileName {
                state.records[index].audioFileName = audioFileName
            }
            if let transcriptFileName {
                state.records[index].transcriptFileName = transcriptFileName
            }
            return
        }
        state.records.append(
            HistoryRecoveryRecordState(
                id: id,
                status: status,
                audioFileName: audioFileName,
                transcriptFileName: transcriptFileName
            )
        )
    }

    private var recoveryDirectoryURL: URL {
        storageRoot.appendingPathComponent(
            HistoryRecoveryLayout.recoveryDirectoryName,
            isDirectory: true
        )
    }

    private func loadState(for snapshotID: UUID) -> HistoryRecoveryState? {
        let url = stateURL(for: snapshotID)
        guard fileManager.fileExists(atPath: url.path),
              let state = try? JSONDecoder().decode(
                HistoryRecoveryState.self,
                from: Data(contentsOf: url)
              ),
              state.schemaVersion == HistoryRecoveryState.currentSchemaVersion,
              state.snapshotID == snapshotID else {
            return nil
        }
        return state
    }

    private func markInspectionFailed(
        for descriptor: HistoryRecoverySnapshotDescriptor
    ) throws {
        guard let currentDescriptor = listSnapshots().first(where: {
            $0.id == descriptor.id && $0.integrity == .ready
        }) else {
            throw HistoryRecoveryServiceError.snapshotNotFound
        }
        var state = currentDescriptor.state ?? HistoryRecoveryState(
            snapshotID: currentDescriptor.id,
            status: .available,
            completedAt: nil
        )
        if state.status != .inspectionFailed {
            state.statusBeforeInspectionFailure = state.status
        }
        state.status = .inspectionFailed
        try saveState(state)
    }

    private func restoreStatusAfterSuccessfulInspection(
        for descriptor: HistoryRecoverySnapshotDescriptor
    ) throws {
        guard let currentDescriptor = listSnapshots().first(where: {
            $0.id == descriptor.id && $0.integrity == .ready
        }),
        var state = currentDescriptor.state,
        state.status == .inspectionFailed else {
            return
        }
        state.status = state.statusBeforeInspectionFailure ?? .available
        state.statusBeforeInspectionFailure = nil
        try saveState(state)
    }

    private func validate(snapshot: HistoryArchiveSnapshot, at snapshotURL: URL) -> Bool {
        guard snapshot.schemaVersion == HistoryArchiveSnapshot.currentSchemaVersion,
              snapshotURL.lastPathComponent.hasSuffix(
                "-\(snapshot.id.uuidString.lowercased())"
              ),
              !snapshot.components.isEmpty,
              !containsSymbolicLink(at: snapshotURL) else {
            return false
        }

        let payloadURL = snapshotURL.appendingPathComponent("payload", isDirectory: true)
        guard isDirectory(payloadURL), !containsSymbolicLink(at: payloadURL) else {
            return false
        }

        var identifiers = Set<HistoryArchiveSnapshotComponent.Identifier>()
        var relativePaths = Set<String>()
        var includesSQLite = false
        for component in snapshot.components {
            guard identifiers.insert(component.identifier).inserted,
                  relativePaths.insert(component.relativePath).inserted,
                  component.relativePath == expectedRelativePath(for: component.identifier),
                  component.isDirectory == expectedIsDirectory(for: component.identifier) else {
                return false
            }
            let componentURL = payloadURL.appendingPathComponent(component.relativePath)
            guard fileManager.fileExists(atPath: componentURL.path),
                  isDirectory(componentURL) == component.isDirectory,
                  !containsSymbolicLink(at: componentURL),
                  byteCount(at: componentURL) == component.byteCount else {
                return false
            }
            includesSQLite = includesSQLite || component.identifier == .sqlite
        }
        return includesSQLite
    }

    private func payloadByteCount(for snapshot: HistoryArchiveSnapshot) -> UInt64 {
        snapshot.components.reduce(0) { $0 + $1.byteCount }
    }

    private func expectedRelativePath(
        for identifier: HistoryArchiveSnapshotComponent.Identifier
    ) -> String {
        switch identifier {
        case .sqlite:
            return "PipelineHistory.sqlite"
        case .sqliteWAL:
            return "PipelineHistory.sqlite-wal"
        case .sqliteSHM:
            return "PipelineHistory.sqlite-shm"
        case .assetReferenceSnapshot:
            return "PipelineHistory-asset-references.json"
        case .audio:
            return "audio"
        case .transcripts:
            return "transcripts"
        case .cloudTranscriptionJobs:
            return "cloud-transcription/jobs"
        case .legacyRecoveryEvidence:
            return "History Recovery"
        }
    }

    private func expectedIsDirectory(
        for identifier: HistoryArchiveSnapshotComponent.Identifier
    ) -> Bool {
        switch identifier {
        case .sqlite, .sqliteWAL, .sqliteSHM, .assetReferenceSnapshot:
            return false
        case .audio, .transcripts, .cloudTranscriptionJobs, .legacyRecoveryEvidence:
            return true
        }
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func containsSymbolicLink(at url: URL) -> Bool {
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            return true
        }
        guard isDirectory(url),
              let enumerator = fileManager.enumerator(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
              ) else {
            return false
        }
        for case let childURL as URL in enumerator {
            if (try? childURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                return true
            }
        }
        return false
    }

    private func byteCount(at url: URL) -> UInt64 {
        guard isDirectory(url) else {
            let attributes = try? fileManager.attributesOfItem(atPath: url.path)
            return (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        }
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
            options: []
        ) else {
            return 0
        }
        var total: UInt64 = 0
        for case let childURL as URL in enumerator {
            let values = try? childURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            guard values?.isDirectory != true else { continue }
            total += UInt64(max(0, values?.fileSize ?? 0))
        }
        return total
    }

    private func writeDurably(_ data: Data, to targetURL: URL) throws {
        let parentURL = targetURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
        let temporaryURL = parentURL.appendingPathComponent(
            ".\(targetURL.lastPathComponent).\(UUID().uuidString).tmp"
        )
        let descriptor = Darwin.open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw HistoryRecoveryServiceError.metadataWriteFailed
        }
        var isOpen = true
        defer {
            if isOpen { Darwin.close(descriptor) }
            try? fileManager.removeItem(at: temporaryURL)
        }

        try writeAll(data, to: descriptor)
        try syncFile(descriptor)
        guard Darwin.close(descriptor) == 0 else {
            isOpen = false
            throw HistoryRecoveryServiceError.metadataWriteFailed
        }
        isOpen = false
        guard Darwin.rename(temporaryURL.path, targetURL.path) == 0 else {
            throw HistoryRecoveryServiceError.metadataWriteFailed
        }
        try syncDirectory(parentURL)
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try HistoryRecoveryDurability.writeAll(data) { pointer, remaining in
            let written = Darwin.write(descriptor, pointer, remaining)
            return (written: written, errorCode: errno)
        }
    }

    private func syncFile(_ descriptor: Int32) throws {
        if fcntl(descriptor, F_FULLFSYNC) == 0 { return }
        guard fsync(descriptor) == 0 else {
            throw HistoryRecoveryServiceError.metadataWriteFailed
        }
    }

    private func syncFile(at url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw HistoryRecoveryServiceError.metadataWriteFailed
        }
        defer { Darwin.close(descriptor) }
        try syncFile(descriptor)
    }

    private func syncDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw HistoryRecoveryServiceError.metadataWriteFailed
        }
        defer { close(descriptor) }
        if fcntl(descriptor, F_FULLFSYNC) == 0 { return }
        guard fsync(descriptor) == 0 else {
            throw HistoryRecoveryServiceError.metadataWriteFailed
        }
    }
}
