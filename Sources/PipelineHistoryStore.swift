import Foundation
import CoreData

struct DeletedPipelineHistoryAssets: Equatable, Sendable {
    let historyID: UUID
    let audioFileName: String?
    let transcriptFileName: String?
}

enum PipelineHistoryStoreError: Error {
    case storeUnavailable
    case durableStoreUnavailable
    case historyEntryNotFound
}

/// A local note write, reported to iCloud sync through `onChange`.
enum PipelineHistoryChange: Equatable, Sendable {
    case saved(UUID)
    /// `wasSynced`: the note had reached iCloud (it has system fields).
    case deleted(UUID, wasSynced: Bool)
}

enum NoteSyncApplyResult: Equatable, Sendable {
    case inserted
    /// `needsUpload`: this Mac had newer field groups, so the merged note
    /// goes back up.
    case updated(needsUpload: Bool)
}

enum PipelineHistorySyncError: Error {
    /// A record for a note this Mac doesn't have lacks a required field.
    case incompleteRecord
    /// A known field holds a value this build can't read.
    case unreadableRecord
}

struct HistoryArchiveSnapshotComponent: Codable, Equatable, Sendable {
    enum Identifier: String, Codable, CaseIterable, Sendable {
        case sqlite
        case sqliteWAL
        case sqliteSHM
        case assetReferenceSnapshot
        case audio
        case transcripts
        case cloudTranscriptionJobs
        case legacyRecoveryEvidence
    }

    let identifier: Identifier
    let relativePath: String
    let byteCount: UInt64
    let isDirectory: Bool
}

struct HistoryArchiveSnapshot: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let id: UUID
    let archivedAt: Date
    let components: [HistoryArchiveSnapshotComponent]
}

enum PipelineHistoryStoreAvailability: Equatable, Sendable {
    case ready
    case unavailable
}

enum PipelineHistoryDurability: Equatable, Sendable {
    case durable
    case inMemory
}

enum PipelineHistoryReferenceTrust: Equatable, Sendable {
    case complete
    case recovered
    case unavailable

    var permitsStartupReferenceCleanup: Bool {
        self == .complete
    }
}

enum PipelineHistoryAssetReferenceSnapshotState: Equatable {
    case matches
    case missing
    case mismatch
    case unavailable
}

private struct PipelineHistoryAssetReferenceSnapshot: Codable, Equatable {
    let audioFileNames: [String]
    let transcriptFileNames: [String]

    init(audioFileNames: Set<String>, transcriptFileNames: Set<String>) {
        self.audioFileNames = audioFileNames.sorted()
        self.transcriptFileNames = transcriptFileNames.sorted()
    }
}

final class PipelineHistoryStore {
    /// Built once and treated as immutable after static initialization. Sharing
    /// the schema prevents multiple entity descriptions from claiming the same
    /// NSManagedObject subclass when several in-memory stores coexist in tests.
    nonisolated(unsafe) private static let managedObjectModel = makeModel()

    private let container: NSPersistentContainer
    private let contextSaver: (NSManagedObjectContext) throws -> Void
    private let historyFetcher: (NSManagedObjectContext, NSFetchRequest<PipelineHistoryEntry>) throws -> [PipelineHistoryEntry]
    private let assetReferenceSnapshotURL: URL?
    private var isStoreLoaded: Bool
    private var canSynchronizeAssetReferenceSnapshot = false
    private(set) var hadPersistentStoreAtLoad: Bool
    private(set) var availability: PipelineHistoryStoreAvailability
    private(set) var loadError: Error?
    private(set) var durability: PipelineHistoryDurability
    private(set) var referenceTrust: PipelineHistoryReferenceTrust
    /// True for stores made in memory on purpose (tests), as opposed to a
    /// durable store that fell back to memory after a load failure.
    private let usesInMemoryStoreByDesign: Bool
    /// The clock used to stamp field changes and deletions. Tests replace it.
    var now: () -> Date = Date.init
    /// Called after every successful local write. Applying a synced record
    /// (`applySynced`, `removeSynced`) never calls it, so nothing echoes.
    var onChange: (([PipelineHistoryChange]) -> Void)?

    private var isDurableStore: Bool {
        durability == .durable
    }

    convenience init() {
        self.init(inMemory: false)
    }

    convenience init(inMemory: Bool) {
        self.init(
            storeURL: inMemory ? nil : Self.defaultStoreURL(),
            usesInMemoryStore: inMemory,
            persistentStoreLoader: Self.loadPersistentStoresSynchronously
        )
    }

    convenience init(storeURL: URL) {
        self.init(
            storeURL: storeURL,
            persistentStoreLoader: Self.loadPersistentStoresSynchronously
        )
    }

    convenience init(
        storeURL: URL,
        persistentStoreLoader: @escaping (NSPersistentContainer) -> Error?
    ) {
        self.init(
            storeURL: storeURL,
            usesInMemoryStore: false,
            persistentStoreLoader: persistentStoreLoader
        )
    }

    convenience init(
        storeURL: URL,
        persistentStoreLoader: @escaping (NSPersistentContainer) -> Error?,
        contextSaver: @escaping (NSManagedObjectContext) throws -> Void
    ) {
        self.init(
            storeURL: storeURL,
            usesInMemoryStore: false,
            persistentStoreLoader: persistentStoreLoader,
            contextSaver: contextSaver
        )
    }

    convenience init(
        storeURL: URL,
        historyFetcher: @escaping (
            NSManagedObjectContext,
            NSFetchRequest<PipelineHistoryEntry>
        ) throws -> [PipelineHistoryEntry]
    ) {
        self.init(
            storeURL: storeURL,
            usesInMemoryStore: false,
            persistentStoreLoader: Self.loadPersistentStoresSynchronously,
            historyFetcher: historyFetcher
        )
    }

    private init(
        storeURL: URL?,
        usesInMemoryStore: Bool,
        persistentStoreLoader: @escaping (NSPersistentContainer) -> Error?,
        contextSaver: @escaping (NSManagedObjectContext) throws -> Void = { context in
            try context.save()
        },
        historyFetcher: @escaping (
            NSManagedObjectContext,
            NSFetchRequest<PipelineHistoryEntry>
        ) throws -> [PipelineHistoryEntry] = { context, request in
            try context.fetch(request)
        }
    ) {
        container = NSPersistentContainer(
            name: "PipelineHistory",
            managedObjectModel: Self.managedObjectModel
        )
        self.contextSaver = contextSaver
        self.historyFetcher = historyFetcher
        assetReferenceSnapshotURL = Self.assetReferenceSnapshotURL(for: storeURL)
        isStoreLoaded = false
        hadPersistentStoreAtLoad = Self.hasPersistentStoreFiles(at: storeURL)
        availability = .ready
        loadError = nil
        durability = usesInMemoryStore ? .inMemory : .durable
        referenceTrust = .unavailable
        usesInMemoryStoreByDesign = usesInMemoryStore

        if usesInMemoryStore {
            configureInMemoryStore()
            loadError = persistentStoreLoader(container)
            isStoreLoaded = loadError == nil
            availability = isStoreLoaded ? .ready : .unavailable
            referenceTrust = .unavailable
            return
        }

        configurePersistentStore(at: storeURL)
        if let error = persistentStoreLoader(container) {
            loadError = error
            availability = .unavailable
            durability = .inMemory
            referenceTrust = .unavailable
            removeLoadedPersistentStores()
            configureInMemoryStore()
            isStoreLoaded = Self.loadPersistentStoresSynchronously(container: container) == nil
            print("[PipelineHistoryStore] Persistent history is unavailable; preserving the original store files.")
            return
        }

        isStoreLoaded = true
        availability = .ready
        durability = .durable
        referenceTrust = Self.makeReferenceTrust(
            isStoreLoaded: true,
            usesInMemoryStore: false,
            storeURL: storeURL
        )
    }

    @discardableResult
    func verifyHistoryReadable() -> Bool {
        guard availability == .ready, isStoreLoaded else {
            referenceTrust = .unavailable
            return false
        }
        var fetchError: Error?
        container.viewContext.performAndWait {
            do {
                let request = pipelineHistoryRequest()
                request.fetchLimit = 1
                request.includesPropertyValues = false
                _ = try historyFetcher(container.viewContext, request)
            } catch {
                fetchError = error
            }
        }
        if let fetchError {
            markHistoryUnavailable(fetchError)
            return false
        }
        return true
    }

    func loadAllHistory() -> [PipelineHistoryItem] {
        guard availability == .ready, isStoreLoaded else {
            referenceTrust = .unavailable
            return []
        }
        var result: [PipelineHistoryItem] = []
        var fetchError: Error?
        container.viewContext.performAndWait {
            do {
                let request = pipelineHistoryRequest()
                request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
                let entities = try historyFetcher(container.viewContext, request)
                result = entities.compactMap(Self.makeHistoryItem(from:))
            } catch {
                fetchError = error
            }
        }
        if let fetchError {
            markHistoryUnavailable(fetchError)
        }
        return result
    }

    private func markHistoryUnavailable(_ error: Error) {
        availability = .unavailable
        isStoreLoaded = false
        loadError = error
        referenceTrust = .unavailable
        canSynchronizeAssetReferenceSnapshot = false
    }

    func detachForHistoryArchive() throws {
        guard availability == .unavailable else {
            throw PipelineHistoryStoreError.storeUnavailable
        }
        try detachPersistentStores()
        isStoreLoaded = false
        canSynchronizeAssetReferenceSnapshot = false
    }

    func detachForArchiveVerification() throws {
        try detachPersistentStores()
    }

    private func detachPersistentStores() throws {
        var thrownError: Error?
        container.viewContext.performAndWait {
            do {
                container.viewContext.reset()
                let coordinator = container.persistentStoreCoordinator
                for store in coordinator.persistentStores {
                    try coordinator.remove(store)
                }
            } catch {
                thrownError = error
            }
        }
        if let thrownError { throw thrownError }
    }

    func assetReferenceSnapshotState(
        audioFileNames: Set<String>,
        transcriptFileNames: Set<String>
    ) -> PipelineHistoryAssetReferenceSnapshotState {
        guard availability == .ready else {
            canSynchronizeAssetReferenceSnapshot = false
            return .unavailable
        }
        guard let assetReferenceSnapshotURL else {
            canSynchronizeAssetReferenceSnapshot = false
            return .unavailable
        }
        guard FileManager.default.fileExists(atPath: assetReferenceSnapshotURL.path) else {
            canSynchronizeAssetReferenceSnapshot = false
            return .missing
        }
        do {
            let snapshot = try JSONDecoder().decode(
                PipelineHistoryAssetReferenceSnapshot.self,
                from: Data(contentsOf: assetReferenceSnapshotURL)
            )
            let currentSnapshot = PipelineHistoryAssetReferenceSnapshot(
                audioFileNames: audioFileNames,
                transcriptFileNames: transcriptFileNames
            )
            let state: PipelineHistoryAssetReferenceSnapshotState = snapshot == currentSnapshot
                ? .matches
                : .mismatch
            canSynchronizeAssetReferenceSnapshot = state == .matches
            return state
        } catch {
            canSynchronizeAssetReferenceSnapshot = false
            return .unavailable
        }
    }

    @discardableResult
    func bootstrapAssetReferenceSnapshot(
        audioFileNames: Set<String>,
        transcriptFileNames: Set<String>
    ) -> Bool {
        guard availability == .ready,
              assetReferenceSnapshotState(
            audioFileNames: audioFileNames,
            transcriptFileNames: transcriptFileNames
        ) == .missing else {
            return false
        }
        do {
            try saveAssetReferenceSnapshot(
                audioFileNames: audioFileNames,
                transcriptFileNames: transcriptFileNames
            )
            canSynchronizeAssetReferenceSnapshot = true
            return true
        } catch {
            return false
        }
    }

    func saveAssetReferenceSnapshot(
        audioFileNames: Set<String>,
        transcriptFileNames: Set<String>
    ) throws {
        guard availability == .ready,
              let assetReferenceSnapshotURL else {
            throw PipelineHistoryStoreError.storeUnavailable
        }
        let snapshot = PipelineHistoryAssetReferenceSnapshot(
            audioFileNames: audioFileNames,
            transcriptFileNames: transcriptFileNames
        )
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: assetReferenceSnapshotURL, options: .atomic)
    }

    func append(_ item: PipelineHistoryItem, maxCount: Int) throws -> [DeletedPipelineHistoryAssets] {
        guard availability == .ready, isStoreLoaded else {
            throw PipelineHistoryStoreError.storeUnavailable
        }
        try insert(item)
        onChange?([.saved(item.id)])
        let deletedAssets = try trim(
            to: maxCount,
            shouldSynchronizeAssetReferenceSnapshot: false
        )
        synchronizeAssetReferenceSnapshot()
        return deletedAssets
    }

    /// `keepsImportedDeletion` is for snapshot imports only: a new row then
    /// keeps the item's `deletedAt`, so a note archived while in Recently
    /// Deleted stays there. Every other save leaves `deletedAt` to
    /// `setDeletedAt`.
    func upsert(
        _ item: PipelineHistoryItem,
        maxCount: Int,
        requiresDurableStore: Bool = false,
        keepsImportedDeletion: Bool = false
    ) throws -> [DeletedPipelineHistoryAssets] {
        guard availability == .ready, isStoreLoaded else {
            throw PipelineHistoryStoreError.storeUnavailable
        }
        if requiresDurableStore, !isDurableStore {
            throw PipelineHistoryStoreError.durableStoreUnavailable
        }

        var thrownError: Error?
        var didChangeSyncedContent = false
        container.viewContext.performAndWait {
            do {
                let request = pipelineHistoryRequest()
                request.predicate = NSPredicate(format: "id == %@", item.id as CVarArg)
                let existing = try container.viewContext.fetch(request).first
                let entity = existing ?? PipelineHistoryEntry(context: container.viewContext)
                didChangeSyncedContent = applyStamping(item, to: entity, isNew: existing == nil)
                if existing == nil, keepsImportedDeletion {
                    entity.deletedAt = item.deletedAt
                }
                try saveContext()
            } catch {
                thrownError = error
            }
        }
        if let thrownError { throw thrownError }
        if didChangeSyncedContent { onChange?([.saved(item.id)]) }
        let deletedAssets = try trim(
            to: maxCount,
            shouldSynchronizeAssetReferenceSnapshot: false
        )
        synchronizeAssetReferenceSnapshot()
        return deletedAssets
    }

    func update(
        _ item: PipelineHistoryItem,
        requiresDurableStore: Bool = false
    ) throws {
        guard availability == .ready, isStoreLoaded else {
            throw PipelineHistoryStoreError.storeUnavailable
        }
        if requiresDurableStore, !isDurableStore {
            throw PipelineHistoryStoreError.durableStoreUnavailable
        }

        var thrownError: Error?
        var didChangeAssetReferences = false
        var didChangeSyncedContent = false
        container.viewContext.performAndWait {
            do {
                let request = pipelineHistoryRequest()
                request.predicate = NSPredicate(format: "id == %@", item.id as CVarArg)
                guard let entity = try container.viewContext.fetch(request).first else {
                    throw PipelineHistoryStoreError.historyEntryNotFound
                }
                didChangeAssetReferences = entity.audioFileName != item.audioFileName
                    || entity.transcriptFileName != item.transcriptFileName
                didChangeSyncedContent = applyStamping(item, to: entity, isNew: false)
                try saveContext()
            } catch {
                thrownError = error
            }
        }
        if let thrownError { throw thrownError }
        if didChangeSyncedContent { onChange?([.saved(item.id)]) }
        if didChangeAssetReferences {
            synchronizeAssetReferenceSnapshot()
        }
    }

    /// Moves a note into Recently Deleted (`date` set) or back out (`nil`).
    /// This is the only writer of `deletedAt`.
    @discardableResult
    func setDeletedAt(_ date: Date?, id: UUID) throws -> PipelineHistoryItem {
        guard availability == .ready, isStoreLoaded else {
            throw PipelineHistoryStoreError.storeUnavailable
        }
        guard isDurableStore || usesInMemoryStoreByDesign else {
            throw PipelineHistoryStoreError.durableStoreUnavailable
        }
        var result: PipelineHistoryItem?
        var thrownError: Error?
        container.viewContext.performAndWait {
            do {
                let request = pipelineHistoryRequest()
                request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
                guard let entity = try container.viewContext.fetch(request).first else {
                    throw PipelineHistoryStoreError.historyEntryNotFound
                }
                let clock = (Self.decodeClock(entity.fieldClockJSON)
                    ?? NoteFieldClock.uniform(entity.timestamp ?? .distantPast))
                    .setting(.deletion, to: now())
                entity.deletedAt = date
                entity.fieldClockJSON = Self.encodeClock(clock)
                try saveContext()
                result = Self.makeHistoryItem(from: entity)
            } catch {
                thrownError = error
            }
        }
        if let thrownError { throw thrownError }
        guard let result else { throw PipelineHistoryStoreError.historyEntryNotFound }
        onChange?([.saved(id)])
        return result
    }

    func delete(
        id: UUID,
        requiresDurableStore: Bool = false,
        beforeDeleting: (DeletedPipelineHistoryAssets) -> Void = { _ in }
    ) throws -> DeletedPipelineHistoryAssets? {
        guard availability == .ready, isStoreLoaded else {
            throw PipelineHistoryStoreError.storeUnavailable
        }
        if requiresDurableStore, !isDurableStore {
            throw PipelineHistoryStoreError.durableStoreUnavailable
        }

        var deletedAssets: DeletedPipelineHistoryAssets?
        var wasSynced = false
        var thrownError: Error?
        container.viewContext.performAndWait {
            do {
                let request = pipelineHistoryRequest()
                request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
                guard let entity = try container.viewContext.fetch(request).first else {
                    throw PipelineHistoryStoreError.historyEntryNotFound
                }
                let assets = Self.deletedAssets(from: entity)
                beforeDeleting(assets)
                deletedAssets = assets
                wasSynced = entity.syncSystemFields != nil
                container.viewContext.delete(entity)
                try saveContext()
            } catch {
                thrownError = error
            }
        }
        if let thrownError { throw thrownError }
        onChange?([.deleted(id, wasSynced: wasSynced)])
        if deletedAssets != nil {
            synchronizeAssetReferenceSnapshot()
        }
        return deletedAssets
    }

    func clearAll(
        requiresDurableStore: Bool = false,
        beforeDeleting: ([DeletedPipelineHistoryAssets]) -> Void = { _ in }
    ) throws -> [DeletedPipelineHistoryAssets] {
        guard availability == .ready, isStoreLoaded else {
            throw PipelineHistoryStoreError.storeUnavailable
        }
        if requiresDurableStore, !isDurableStore {
            throw PipelineHistoryStoreError.durableStoreUnavailable
        }

        var deletedAssets: [DeletedPipelineHistoryAssets] = []
        var changes: [PipelineHistoryChange] = []
        var thrownError: Error?
        container.viewContext.performAndWait {
            do {
                let request = pipelineHistoryRequest()
                request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
                let entities = try historyFetcher(container.viewContext, request)
                deletedAssets = entities.map(Self.deletedAssets(from:))
                beforeDeleting(deletedAssets)
                changes = entities.compactMap(Self.deletionChange(for:))
                for entity in entities {
                    container.viewContext.delete(entity)
                }
                try saveContext()
            } catch {
                thrownError = error
            }
        }
        if let thrownError { throw thrownError }
        if !changes.isEmpty { onChange?(changes) }
        if !deletedAssets.isEmpty {
            synchronizeAssetReferenceSnapshot()
        }
        return deletedAssets
    }

    func trim(
        to maxCount: Int,
        beforeDeleting: ([DeletedPipelineHistoryAssets]) -> Void = { _ in },
        shouldSynchronizeAssetReferenceSnapshot: Bool = true
    ) throws -> [DeletedPipelineHistoryAssets] {
        guard availability == .ready, isStoreLoaded else {
            throw PipelineHistoryStoreError.storeUnavailable
        }
        guard maxCount > 0 else {
            let deletedAssets = try clearAll(beforeDeleting: beforeDeleting)
            return deletedAssets
        }

        var deletedAssets: [DeletedPipelineHistoryAssets] = []
        var changes: [PipelineHistoryChange] = []
        var thrownError: Error?
        container.viewContext.performAndWait {
            do {
                let request = pipelineHistoryRequest()
                request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
                let entities = try historyFetcher(container.viewContext, request)
                guard entities.count > maxCount else { return }
                let dropped = entities[maxCount...]
                deletedAssets = dropped.map(Self.deletedAssets(from:))
                beforeDeleting(deletedAssets)
                changes = dropped.compactMap(Self.deletionChange(for:))
                for entity in dropped {
                    container.viewContext.delete(entity)
                }
                try saveContext()
            } catch {
                thrownError = error
            }
        }
        if let thrownError { throw thrownError }
        if !changes.isEmpty { onChange?(changes) }
        if shouldSynchronizeAssetReferenceSnapshot, !deletedAssets.isEmpty {
            synchronizeAssetReferenceSnapshot()
        }
        return deletedAssets
    }

    // MARK: - iCloud sync

    /// The note as it travels to other Macs, with the unknown keys a newer
    /// build sent kept.
    func syncRecord(id: UUID) -> NoteSyncRecord? {
        var record: NoteSyncRecord?
        container.viewContext.performAndWait {
            record = (try? fetchEntry(id: id)).flatMap { $0.map(Self.syncRecord(from:)) }
        }
        return record
    }

    func syncSystemFields(id: UUID) -> Data? {
        var data: Data?
        container.viewContext.performAndWait {
            data = (try? fetchEntry(id: id))??.syncSystemFields
        }
        return data
    }

    func setSyncSystemFields(_ data: Data?, id: UUID) {
        container.viewContext.performAndWait {
            guard let entity = (try? fetchEntry(id: id)) ?? nil else { return }
            entity.syncSystemFields = data
            try? saveContext()
        }
    }

    /// Forgets which notes reached iCloud, after the iCloud data went away
    /// (account change, or deleted from iCloud).
    func clearAllSyncSystemFields() {
        container.viewContext.performAndWait {
            let request = pipelineHistoryRequest()
            request.predicate = NSPredicate(format: "syncSystemFields != nil")
            guard let entities = try? historyFetcher(container.viewContext, request) else { return }
            for entity in entities { entity.syncSystemFields = nil }
            try? saveContext()
        }
    }

    /// Every note settled enough to send, Recently Deleted included.
    func syncableNoteIDs() -> [UUID] {
        var ids: [UUID] = []
        container.viewContext.performAndWait {
            let request = pipelineHistoryRequest()
            request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
            let entities = (try? historyFetcher(container.viewContext, request)) ?? []
            ids = entities.map(Self.makeHistoryItem(from:))
                .filter(NoteSyncEligibility.isSyncable)
                .map(\.id)
        }
        return ids
    }

    func isSyncable(id: UUID) -> Bool {
        var syncable = false
        container.viewContext.performAndWait {
            if let entity = (try? fetchEntry(id: id)) ?? nil {
                syncable = NoteSyncEligibility.isSyncable(Self.makeHistoryItem(from: entity))
            }
        }
        return syncable
    }

    /// Saves a record from iCloud, merged field group by field group with
    /// the note on this Mac. The merged clock and deletion are written as
    /// they are, never re-stamped, and `onChange` is not called.
    func applySynced(_ record: NoteSyncRecord, systemFields: Data?) throws -> NoteSyncApplyResult {
        guard availability == .ready, isStoreLoaded else {
            throw PipelineHistoryStoreError.storeUnavailable
        }
        guard !record.hasUnreadableKnownFields else {
            throw PipelineHistorySyncError.unreadableRecord
        }
        var remote = record
        remote.clock = record.clock.roundedToMilliseconds()
        var result: NoteSyncApplyResult?
        var didChangeAssetReferences = false
        var thrownError: Error?
        container.viewContext.performAndWait {
            do {
                let existing = try fetchEntry(id: remote.noteID)
                let merged: NoteSyncRecord
                let item: PipelineHistoryItem
                let entity: PipelineHistoryEntry
                if let existing {
                    merged = NoteSyncMerge.merge(local: Self.syncRecord(from: existing), remote: remote)
                    item = merged.applied(onto: Self.makeHistoryItem(from: existing))
                    didChangeAssetReferences = existing.audioFileName != item.audioFileName
                        || existing.transcriptFileName != item.transcriptFileName
                    entity = existing
                    result = .updated(needsUpload: merged != remote)
                } else {
                    guard let newItem = remote.newNote() else {
                        throw PipelineHistorySyncError.incompleteRecord
                    }
                    merged = remote
                    item = newItem
                    entity = PipelineHistoryEntry(context: container.viewContext)
                    didChangeAssetReferences = true
                    result = .inserted
                }
                Self.apply(item, to: entity)
                entity.fieldClockJSON = Self.encodeClock(merged.clock)
                entity.deletedAt = merged.deletedAt
                entity.syncExtraFieldsJSON = Self.encodeExtraFields(merged.fields)
                if let systemFields { entity.syncSystemFields = systemFields }
                try saveContext()
            } catch {
                container.viewContext.rollback()
                thrownError = error
            }
        }
        if let thrownError { throw thrownError }
        if didChangeAssetReferences { synchronizeAssetReferenceSnapshot() }
        guard let result else { throw PipelineHistoryStoreError.historyEntryNotFound }
        return result
    }

    /// Deletes a note that was deleted in iCloud. `onChange` is not called.
    /// Returns nil when the note is already gone.
    func removeSynced(id: UUID) throws -> DeletedPipelineHistoryAssets? {
        guard availability == .ready, isStoreLoaded else {
            throw PipelineHistoryStoreError.storeUnavailable
        }
        var deletedAssets: DeletedPipelineHistoryAssets?
        var thrownError: Error?
        container.viewContext.performAndWait {
            do {
                guard let entity = try fetchEntry(id: id) else { return }
                deletedAssets = Self.deletedAssets(from: entity)
                container.viewContext.delete(entity)
                try saveContext()
            } catch {
                thrownError = error
            }
        }
        if let thrownError { throw thrownError }
        if deletedAssets != nil { synchronizeAssetReferenceSnapshot() }
        return deletedAssets
    }

    /// Call inside `performAndWait`.
    private func fetchEntry(id: UUID) throws -> PipelineHistoryEntry? {
        let request = pipelineHistoryRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        return try container.viewContext.fetch(request).first
    }

    private static func deletionChange(for entity: PipelineHistoryEntry) -> PipelineHistoryChange? {
        .deleted(entity.id, wasSynced: entity.syncSystemFields != nil)
    }

    private static let knownSyncKeys = Set(NoteSyncField.allCases.map(\.rawValue))

    private static func syncRecord(from entity: PipelineHistoryEntry) -> NoteSyncRecord {
        var record = NoteSyncRecord(item: makeHistoryItem(from: entity))
        let extras = entity.syncExtraFieldsJSON.flatMap { try? NoteSyncPayload.decodeFields($0) } ?? [:]
        for (key, value) in extras {
            if key == NoteSyncRecord.schemaVersionKey {
                if case .int(let kept) = value, case .int(let current)? = record.fields[key], kept > current {
                    record.fields[key] = value
                }
            } else if record.fields[key] == nil {
                record.fields[key] = value
            }
        }
        return record
    }

    /// Keys this build doesn't know, plus a newer schema version.
    private static func encodeExtraFields(_ fields: [String: NoteSyncValue]) -> Data? {
        let extras = fields.filter { key, value in
            if key == NoteSyncRecord.schemaVersionKey {
                if case .int(let version) = value { return version > NoteSyncRecord.schemaVersion }
                return true
            }
            return !knownSyncKeys.contains(key)
        }
        return extras.isEmpty ? nil : try? NoteSyncPayload.encodeFields(extras)
    }

    private func insert(_ item: PipelineHistoryItem) throws {
        guard isStoreLoaded else { return }

        var thrownError: Error?
        container.viewContext.performAndWait {
            do {
                let context = container.viewContext
                let entity = PipelineHistoryEntry(context: context)
                applyStamping(item, to: entity, isNew: true)
                try saveContext()
            } catch {
                thrownError = error
            }
        }
        if let thrownError { throw thrownError }
    }

    /// Applies `item` and advances the clock of the field groups it
    /// changed. `deletedAt` is left alone: only `setDeletedAt` and a
    /// snapshot import write it.
    /// Returns whether a synced field group changed (always for a new row),
    /// so only those writes are reported to sync.
    @discardableResult
    private func applyStamping(
        _ item: PipelineHistoryItem,
        to entity: PipelineHistoryEntry,
        isNew: Bool
    ) -> Bool {
        let previous = isNew ? nil : Self.makeHistoryItem(from: entity)
        let existing = isNew ? nil : Self.decodeClock(entity.fieldClockJSON)
        let clock = NoteFieldClock.stamped(
            previous: previous,
            current: item,
            existing: existing,
            now: now()
        )
        Self.apply(item, to: entity)
        entity.fieldClockJSON = Self.encodeClock(clock)
        guard let previous, existing != nil else { return true }
        return !NoteFieldClock.changedGroups(from: previous, to: item).isEmpty
    }

    private static func decodeClock(_ data: Data?) -> NoteFieldClock? {
        data.flatMap { try? JSONDecoder().decode(NoteFieldClock.self, from: $0) }
    }

    private static func encodeClock(_ clock: NoteFieldClock) -> Data? {
        try? JSONEncoder().encode(clock)
    }

    private static func apply(
        _ item: PipelineHistoryItem,
        to entity: PipelineHistoryEntry
    ) {
        entity.id = item.id
        entity.intent = item.intent.rawValue
        entity.selectedText = item.selectedText
        entity.capturedSelection = item.capturedSelection
        entity.timestamp = item.timestamp
        entity.recordingStartedAt = item.recordingStartedAt
        entity.recordingEndedAt = item.recordingEndedAt
        entity.calendarMatchJSON = encodeCalendarMatch(item.calendarMatch)
        entity.rawTranscript = item.rawTranscript
        entity.postProcessedTranscript = item.postProcessedTranscript
        entity.postProcessingPrompt = item.postProcessingPrompt
        entity.systemPrompt = item.systemPrompt
        entity.contextSummary = item.contextSummary
        entity.contextSystemPrompt = item.contextSystemPrompt
        entity.contextPrompt = item.contextPrompt
        entity.contextScreenshotDataURL = item.contextScreenshotDataURL
        entity.contextScreenshotStatus = item.contextScreenshotStatus
        entity.postProcessingStatus = item.postProcessingStatus
        entity.aiProcessingOutcome = item.aiProcessingOutcome
        entity.debugStatus = item.debugStatus
        entity.customVocabulary = item.customVocabulary
        entity.customSystemPrompt = item.customSystemPrompt
        entity.audioFileName = item.audioFileName
        entity.usedLocalTranscription = item.usedLocalTranscription
        entity.usedContextCapture = item.usedContextCapture
        entity.usedPostProcessing = item.usedPostProcessing
        entity.transcriptionLanguageCode = item.transcriptionLanguageCode
        entity.spokenLanguageCode = item.spokenLanguageCode
        entity.spokenLanguageResolution = item.spokenLanguageResolution?.rawValue
        entity.meetingSummaryAttemptJSON = encodeMeetingSummaryAttempt(
            item.meetingSummaryAttempt
        )
        entity.localTranscriptionModelID = item.localTranscriptionModelID
        entity.transcriptFileName = item.transcriptFileName
        entity.contextAppName = item.contextAppName
        entity.contextBundleIdentifier = item.contextBundleIdentifier
        entity.contextWindowTitle = item.contextWindowTitle
        entity.customTitle = item.customTitle
        entity.meetingSummaryJSON = item.meetingSummaryJSON
    }

    private func saveContext() throws {
        guard container.viewContext.hasChanges else { return }
        do {
            try contextSaver(container.viewContext)
        } catch {
            container.viewContext.rollback()
            throw error
        }
    }

    private func synchronizeAssetReferenceSnapshot() {
        guard canSynchronizeAssetReferenceSnapshot,
              referenceTrust.permitsStartupReferenceCleanup,
              let fileNames = loadAssetReferenceFileNames() else {
            return
        }
        do {
            try saveAssetReferenceSnapshot(
                audioFileNames: fileNames.audio,
                transcriptFileNames: fileNames.transcripts
            )
        } catch {
            canSynchronizeAssetReferenceSnapshot = false
            referenceTrust = .unavailable
        }
    }

    private func loadAssetReferenceFileNames() -> (
        audio: Set<String>,
        transcripts: Set<String>
    )? {
        guard availability == .ready, isStoreLoaded else { return nil }
        var audioFileNames = Set<String>()
        var transcriptFileNames = Set<String>()
        var fetchError: Error?
        container.viewContext.performAndWait {
            do {
                let request = NSFetchRequest<NSDictionary>(entityName: "PipelineHistoryEntry")
                request.resultType = .dictionaryResultType
                request.propertiesToFetch = ["audioFileName", "transcriptFileName"]
                let rows = try container.viewContext.fetch(request)
                audioFileNames = Set(rows.compactMap { $0["audioFileName"] as? String })
                transcriptFileNames = Set(rows.compactMap { $0["transcriptFileName"] as? String })
            } catch {
                fetchError = error
            }
        }
        if let fetchError {
            markHistoryUnavailable(fetchError)
            return nil
        }
        return (audioFileNames, transcriptFileNames)
    }

    private func pipelineHistoryRequest() -> NSFetchRequest<PipelineHistoryEntry> {
        NSFetchRequest<PipelineHistoryEntry>(entityName: "PipelineHistoryEntry")
    }

    private static func deletedAssets(from entity: PipelineHistoryEntry) -> DeletedPipelineHistoryAssets {
        DeletedPipelineHistoryAssets(
            historyID: entity.id,
            audioFileName: entity.audioFileName,
            transcriptFileName: entity.transcriptFileName
        )
    }

    private func configurePersistentStore(at storeURL: URL?) {
        if let storeURL {
            let description = NSPersistentStoreDescription(url: storeURL)
            description.shouldMigrateStoreAutomatically = true
            description.shouldInferMappingModelAutomatically = true
            container.persistentStoreDescriptions = [description]
        } else {
            container.persistentStoreDescriptions = [NSPersistentStoreDescription()]
        }
    }

    private func configureInMemoryStore() {
        removeLoadedPersistentStores()
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]
    }

    private func removeLoadedPersistentStores() {
        let coordinator = container.persistentStoreCoordinator
        for store in coordinator.persistentStores {
            try? coordinator.remove(store)
        }
    }

    private enum RecoveryBackupInspection {
        case absent
        case present
        case unavailable
    }

    private static func makeReferenceTrust(
        isStoreLoaded: Bool,
        usesInMemoryStore: Bool,
        storeURL: URL?
    ) -> PipelineHistoryReferenceTrust {
        guard isStoreLoaded, !usesInMemoryStore else {
            return .unavailable
        }
        switch inspectRecoveryBackups(near: storeURL) {
        case .present:
            return .recovered
        case .unavailable:
            return .unavailable
        case .absent:
            return .complete
        }
    }

    private static func hasPersistentStoreFiles(at storeURL: URL?) -> Bool {
        guard let storeURL else { return false }
        return FileManager.default.fileExists(atPath: storeURL.path)
    }

    private static func assetReferenceSnapshotURL(for storeURL: URL?) -> URL? {
        guard let storeURL else { return nil }
        let storeName = storeURL.deletingPathExtension().lastPathComponent
        return storeURL.deletingLastPathComponent().appendingPathComponent(
            "\(storeName)-asset-references.json"
        )
    }

    private static func inspectRecoveryBackups(
        near storeURL: URL?
    ) -> RecoveryBackupInspection {
        guard let storeURL else { return .absent }
        let archiveInspection = inspectPublishedHistoryArchives(near: storeURL)
        switch archiveInspection {
        case .present, .unavailable:
            return archiveInspection
        case .absent:
            return inspectLegacyRecoveryEvidence(near: storeURL)
        }
    }

    private static func inspectPublishedHistoryArchives(
        near storeURL: URL
    ) -> RecoveryBackupInspection {
        let recoveryRootURL = storeURL.deletingLastPathComponent()
            .appendingPathComponent("Recovery", isDirectory: true)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: recoveryRootURL.path) else {
            return .absent
        }
        let transactionsURL = recoveryRootURL.appendingPathComponent(
            ".transactions",
            isDirectory: true
        )
        if fileManager.fileExists(atPath: transactionsURL.path) {
            do {
                guard try transactionsURL.resourceValues(forKeys: [.isDirectoryKey])
                    .isDirectory == true,
                      try fileManager.contentsOfDirectory(atPath: transactionsURL.path).isEmpty else {
                    return .unavailable
                }
            } catch {
                return .unavailable
            }
        }
        do {
            let entries = try fileManager.contentsOfDirectory(
                at: recoveryRootURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            var hasPublishedArchive = false
            for entry in entries {
                let isDirectory = try entry.resourceValues(forKeys: [.isDirectoryKey])
                    .isDirectory == true
                if entry.lastPathComponent == ".transactions" {
                    guard isDirectory else { return .unavailable }
                    if try !fileManager.contentsOfDirectory(atPath: entry.path).isEmpty {
                        return .unavailable
                    }
                    continue
                }
                guard entry.lastPathComponent.hasPrefix("history-") else { continue }
                guard isDirectory else { return .unavailable }
                let manifestURL = entry.appendingPathComponent("manifest.json")
                let payloadURL = entry.appendingPathComponent("payload", isDirectory: true)
                guard fileManager.fileExists(atPath: manifestURL.path),
                      fileManager.fileExists(atPath: payloadURL.path) else {
                    return .unavailable
                }
                let manifest = try JSONDecoder().decode(
                    HistoryArchiveSnapshot.self,
                    from: Data(contentsOf: manifestURL)
                )
                guard manifest.schemaVersion == HistoryArchiveSnapshot.currentSchemaVersion,
                      entry.lastPathComponent.hasSuffix(
                        "-\(manifest.id.uuidString.lowercased())"
                      ) else {
                    return .unavailable
                }
                hasPublishedArchive = true
            }
            return hasPublishedArchive ? .present : .absent
        } catch {
            return .unavailable
        }
    }

    private static func inspectLegacyRecoveryEvidence(
        near storeURL: URL
    ) -> RecoveryBackupInspection {
        let recoveryRootURL = storeURL.deletingLastPathComponent()
            .appendingPathComponent("History Recovery", isDirectory: true)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: recoveryRootURL.path) else {
            return .absent
        }
        do {
            let entries = try fileManager.contentsOfDirectory(
                at: recoveryRootURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            for entry in entries {
                guard try entry.resourceValues(forKeys: [.isDirectoryKey])
                    .isDirectory == true else {
                    continue
                }
                return .present
            }
            return .absent
        } catch {
            return .unavailable
        }
    }

    private static func defaultStoreURL() -> URL? {
        let baseURL = AppName.applicationSupportDirectory
        try? FileManager.default.createDirectory(
            at: baseURL,
            withIntermediateDirectories: true
        )
        return baseURL.appendingPathComponent("PipelineHistory.sqlite")
    }

    // Safe: loadPersistentStores calls back on a private queue, not the calling thread.
    static func loadPersistentStoresSynchronously(container: NSPersistentContainer) -> Error? {
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var capturedError: Error?
        var remainingCompletions = max(1, container.persistentStoreDescriptions.count)

        container.loadPersistentStores { _, error in
            lock.lock()
            if capturedError == nil, let error {
                capturedError = error
            }
            remainingCompletions -= 1
            let shouldSignal = remainingCompletions <= 0
            lock.unlock()

            if shouldSignal {
                semaphore.signal()
            }
        }

        semaphore.wait()
        return capturedError
    }

    private static func encodeCalendarMatch(_ match: CalendarEventMatch?) -> String? {
        guard let match, let data = try? JSONEncoder().encode(match) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func decodeCalendarMatch(_ json: String?) -> CalendarEventMatch? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(CalendarEventMatch.self, from: data)
    }

    private static func encodeMeetingSummaryAttempt(
        _ attempt: MeetingSummaryAttempt?
    ) -> Data? {
        attempt.flatMap { try? JSONEncoder().encode($0) }
    }

    private static func makeHistoryItem(from entity: PipelineHistoryEntry) -> PipelineHistoryItem {
        PipelineHistoryItem(
            intent: PipelineHistoryItemIntent(rawValue: entity.intent ?? "") ?? .dictation,
            selectedText: entity.selectedText,
            capturedSelection: entity.capturedSelection,
            id: entity.id,
            timestamp: entity.timestamp ?? Date(),
            recordingStartedAt: entity.recordingStartedAt,
            recordingEndedAt: entity.recordingEndedAt,
            calendarMatch: decodeCalendarMatch(entity.calendarMatchJSON),
            rawTranscript: entity.rawTranscript ?? "",
            postProcessedTranscript: entity.postProcessedTranscript ?? "",
            postProcessingPrompt: entity.postProcessingPrompt,
            systemPrompt: entity.systemPrompt,
            contextSummary: entity.contextSummary ?? "",
            contextSystemPrompt: entity.contextSystemPrompt,
            contextPrompt: entity.contextPrompt,
            contextScreenshotDataURL: entity.contextScreenshotDataURL,
            contextScreenshotStatus: entity.contextScreenshotStatus ?? "available (image)",
            postProcessingStatus: entity.postProcessingStatus ?? "",
            aiProcessingOutcome: entity.aiProcessingOutcome ?? "succeeded",
            debugStatus: entity.debugStatus ?? "",
            customVocabulary: entity.customVocabulary ?? "",
            customSystemPrompt: entity.customSystemPrompt ?? "",
            audioFileName: entity.audioFileName,
            usedLocalTranscription: entity.usedLocalTranscription,
            usedContextCapture: entity.usedContextCapture,
            usedPostProcessing: entity.usedPostProcessing,
            transcriptionLanguageCode: entity.transcriptionLanguageCode ?? "auto",
            spokenLanguageCode: entity.spokenLanguageCode,
            spokenLanguageResolution: entity.spokenLanguageResolution.flatMap(
                SpokenLanguageResolutionSource.init(rawValue:)
            ),
            meetingSummaryAttempt: entity.meetingSummaryAttemptJSON.flatMap {
                try? JSONDecoder().decode(MeetingSummaryAttempt.self, from: $0)
            },
            localTranscriptionModelID: entity.localTranscriptionModelID ?? TranscriptionModel.default.id,
            transcriptFileName: entity.transcriptFileName,
            contextAppName: entity.contextAppName,
            contextBundleIdentifier: entity.contextBundleIdentifier,
            contextWindowTitle: entity.contextWindowTitle,
            customTitle: entity.customTitle,
            meetingSummaryJSON: entity.meetingSummaryJSON,
            deletedAt: entity.deletedAt,
            fieldClock: decodeClock(entity.fieldClockJSON)
                ?? NoteFieldClock.uniform(entity.timestamp ?? .distantPast)
        )
    }

    private static func makeModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()

        let entity = NSEntityDescription()
        entity.name = "PipelineHistoryEntry"
        entity.managedObjectClassName = NSStringFromClass(PipelineHistoryEntry.self)

        entity.properties = [
            makeAttribute(name: "intent", type: .stringAttributeType, isOptional: true, defaultValue: "dictation"),
            makeAttribute(name: "selectedText", type: .stringAttributeType, isOptional: true),
            makeAttribute(name: "capturedSelection", type: .stringAttributeType, isOptional: true),
            makeAttribute(name: "id", type: .UUIDAttributeType, isOptional: false),
            makeAttribute(name: "timestamp", type: .dateAttributeType, isOptional: false),
            makeAttribute(name: "recordingStartedAt", type: .dateAttributeType, isOptional: true),
            makeAttribute(name: "recordingEndedAt", type: .dateAttributeType, isOptional: true),
            makeAttribute(name: "calendarMatchJSON", type: .stringAttributeType, isOptional: true),
            makeAttribute(name: "rawTranscript", type: .stringAttributeType, isOptional: false),
            makeAttribute(name: "postProcessedTranscript", type: .stringAttributeType, isOptional: false),
            makeAttribute(name: "postProcessingPrompt", type: .stringAttributeType, isOptional: true),
            makeAttribute(name: "systemPrompt", type: .stringAttributeType, isOptional: true),
            makeAttribute(name: "contextSummary", type: .stringAttributeType, isOptional: false),
            makeAttribute(name: "contextSystemPrompt", type: .stringAttributeType, isOptional: true),
            makeAttribute(name: "contextPrompt", type: .stringAttributeType, isOptional: true),
            makeAttribute(name: "contextScreenshotDataURL", type: .stringAttributeType, isOptional: true),
            makeAttribute(name: "contextScreenshotStatus", type: .stringAttributeType, isOptional: false),
            makeAttribute(name: "postProcessingStatus", type: .stringAttributeType, isOptional: false),
            makeAttribute(name: "aiProcessingOutcome", type: .stringAttributeType, isOptional: true),
            makeAttribute(name: "debugStatus", type: .stringAttributeType, isOptional: false),
            makeAttribute(name: "customVocabulary", type: .stringAttributeType, isOptional: false),
            makeAttribute(name: "customSystemPrompt", type: .stringAttributeType, isOptional: false, defaultValue: ""),
            makeAttribute(name: "audioFileName", type: .stringAttributeType, isOptional: true),
            makeAttribute(name: "usedLocalTranscription", type: .booleanAttributeType, isOptional: false),
            makeAttribute(name: "usedContextCapture", type: .booleanAttributeType, isOptional: false),
            makeAttribute(name: "usedPostProcessing", type: .booleanAttributeType, isOptional: false),
            makeAttribute(name: "transcriptionLanguageCode", type: .stringAttributeType, isOptional: true),
            makeAttribute(name: "spokenLanguageCode", type: .stringAttributeType, isOptional: true),
            makeAttribute(name: "spokenLanguageResolution", type: .stringAttributeType, isOptional: true),
            makeAttribute(name: "meetingSummaryAttemptJSON", type: .binaryDataAttributeType, isOptional: true),
            makeAttribute(name: "localTranscriptionModelID", type: .stringAttributeType, isOptional: false, defaultValue: "mlx-community/whisper-large-v3-turbo"),
            makeAttribute(name: "transcriptFileName", type: .stringAttributeType, isOptional: true),
            makeAttribute(name: "contextAppName", type: .stringAttributeType, isOptional: true),
            makeAttribute(name: "contextBundleIdentifier", type: .stringAttributeType, isOptional: true),
            makeAttribute(name: "contextWindowTitle", type: .stringAttributeType, isOptional: true),
            makeAttribute(name: "customTitle", type: .stringAttributeType, isOptional: true),
            makeAttribute(name: "meetingSummaryJSON", type: .binaryDataAttributeType, isOptional: true),
            makeAttribute(name: "deletedAt", type: .dateAttributeType, isOptional: true),
            makeAttribute(name: "fieldClockJSON", type: .binaryDataAttributeType, isOptional: true),
            makeAttribute(name: "syncExtraFieldsJSON", type: .binaryDataAttributeType, isOptional: true),
            makeAttribute(name: "syncSystemFields", type: .binaryDataAttributeType, isOptional: true)
        ]

        model.entities = [entity]
        return model
    }

    private static func makeAttribute(
        name: String,
        type: NSAttributeType,
        isOptional: Bool,
        defaultValue: Any? = nil
    ) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = type
        attribute.isOptional = isOptional
        attribute.defaultValue = defaultValue
        return attribute
    }

    func clearFieldClockForTesting(id: UUID) {
        container.viewContext.performAndWait {
            let request = pipelineHistoryRequest()
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            if let entity = try? container.viewContext.fetch(request).first {
                entity.fieldClockJSON = nil
                try? container.viewContext.save()
            }
        }
    }

    /// Writes a store with the model as it was before `deletedAt`,
    /// `fieldClockJSON`, and the sync attributes, holding one synthetic row.
    static func writeLegacyStoreForTesting(at url: URL, id: UUID, timestamp: Date) throws {
        let model = makeModel()
        let entity = model.entities[0]
        // A plain NSManagedObject, so this second model never claims the
        // PipelineHistoryEntry class that the shared model owns.
        entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        entity.properties = entity.properties.filter {
            !["deletedAt", "fieldClockJSON", "syncExtraFieldsJSON", "syncSystemFields"].contains($0.name)
        }
        let container = NSPersistentContainer(name: "PipelineHistory", managedObjectModel: model)
        let description = NSPersistentStoreDescription(url: url)
        description.shouldAddStoreAsynchronously = false
        container.persistentStoreDescriptions = [description]
        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError { throw loadError }
        let row = NSEntityDescription.insertNewObject(
            forEntityName: "PipelineHistoryEntry",
            into: container.viewContext
        )
        row.setValue(id, forKey: "id")
        row.setValue(timestamp, forKey: "timestamp")
        row.setValue("synthetic raw", forKey: "rawTranscript")
        row.setValue("", forKey: "postProcessedTranscript")
        row.setValue("", forKey: "contextSummary")
        row.setValue("No screenshot", forKey: "contextScreenshotStatus")
        row.setValue("succeeded", forKey: "postProcessingStatus")
        row.setValue("", forKey: "debugStatus")
        row.setValue("", forKey: "customVocabulary")
        for flag in ["usedLocalTranscription", "usedContextCapture", "usedPostProcessing"] {
            row.setValue(false, forKey: flag)
        }
        try container.viewContext.save()
        for store in container.persistentStoreCoordinator.persistentStores {
            try container.persistentStoreCoordinator.remove(store)
        }
    }
}

@objc(PipelineHistoryEntry)
final class PipelineHistoryEntry: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var intent: String?
    @NSManaged var selectedText: String?
    @NSManaged var capturedSelection: String?
    @NSManaged var timestamp: Date?
    @NSManaged var recordingStartedAt: Date?
    @NSManaged var recordingEndedAt: Date?
    @NSManaged var calendarMatchJSON: String?
    @NSManaged var rawTranscript: String?
    @NSManaged var postProcessedTranscript: String?
    @NSManaged var postProcessingPrompt: String?
    @NSManaged var systemPrompt: String?
    @NSManaged var contextSummary: String?
    @NSManaged var contextSystemPrompt: String?
    @NSManaged var contextPrompt: String?
    @NSManaged var contextScreenshotDataURL: String?
    @NSManaged var contextScreenshotStatus: String?
    @NSManaged var postProcessingStatus: String?
    @NSManaged var aiProcessingOutcome: String?
    @NSManaged var debugStatus: String?
    @NSManaged var customVocabulary: String?
    @NSManaged var customSystemPrompt: String?
    @NSManaged var audioFileName: String?
    @NSManaged var usedLocalTranscription: Bool
    @NSManaged var usedContextCapture: Bool
    @NSManaged var usedPostProcessing: Bool
    @NSManaged var transcriptionLanguageCode: String?
    @NSManaged var spokenLanguageCode: String?
    @NSManaged var spokenLanguageResolution: String?
    @NSManaged var meetingSummaryAttemptJSON: Data?
    @NSManaged var localTranscriptionModelID: String?
    @NSManaged var transcriptFileName: String?
    @NSManaged var contextAppName: String?
    @NSManaged var contextBundleIdentifier: String?
    @NSManaged var contextWindowTitle: String?
    @NSManaged var customTitle: String?
    @NSManaged var meetingSummaryJSON: Data?
    @NSManaged var deletedAt: Date?
    @NSManaged var fieldClockJSON: Data?
    @NSManaged var syncExtraFieldsJSON: Data?
    @NSManaged var syncSystemFields: Data?
}
