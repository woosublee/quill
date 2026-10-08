import CoreData
import Foundation

@main
struct PipelineHistoryRecentlyDeletedStoreTests {
    static func main() throws {
        try testInsertStampsEveryGroup()
        try testUpdateStampsOnlyChangedGroups()
        try testSetDeletedAtRoundTripsAndStampsDeletion()
        try testUpdateNeverClearsDeletedAt()
        try testLoadIncludesDeletedRows()
        try testRowWithoutClockGetsTimestampClock()
        try testStoreWithoutNewAttributesOpens()
        try testNewRowKeepsDeletionFromImportedItem()
        print("PipelineHistoryRecentlyDeletedStoreTests passed")
    }

    private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private static func makeItem(id: UUID = UUID(), title: String? = nil) -> PipelineHistoryItem {
        PipelineHistoryItem(
            id: id,
            timestamp: t0,
            rawTranscript: "synthetic raw",
            postProcessedTranscript: "synthetic edited",
            postProcessingPrompt: nil,
            contextSummary: "",
            contextScreenshotDataURL: nil,
            contextScreenshotStatus: "No screenshot",
            postProcessingStatus: "succeeded",
            debugStatus: "",
            customVocabulary: "",
            customTitle: title
        )
    }

    private static func store(at clock: Date) -> PipelineHistoryStore {
        let store = PipelineHistoryStore(inMemory: true)
        store.now = { clock }
        return store
    }

    private static func load(_ store: PipelineHistoryStore, _ id: UUID) -> PipelineHistoryItem {
        store.loadAllHistory().first { $0.id == id }!
    }

    private static func testInsertStampsEveryGroup() throws {
        let s = store(at: t0.addingTimeInterval(1))
        let item = makeItem()
        _ = try s.append(item, maxCount: Int.max)
        let clock = load(s, item.id).fieldClock!
        precondition(NoteFieldGroup.allCases.allSatisfy { clock.stamp(for: $0) == t0.addingTimeInterval(1) })
    }

    private static func testUpdateStampsOnlyChangedGroups() throws {
        let s = store(at: t0.addingTimeInterval(1))
        let item = makeItem(title: "A")
        _ = try s.append(item, maxCount: Int.max)
        s.now = { t0.addingTimeInterval(9) }
        try s.update(makeItem(id: item.id, title: "B"))
        let clock = load(s, item.id).fieldClock!
        precondition(clock.stamp(for: .title) == t0.addingTimeInterval(9))
        precondition(clock.stamp(for: .rawTranscript) == t0.addingTimeInterval(1))
    }

    private static func testSetDeletedAtRoundTripsAndStampsDeletion() throws {
        let s = store(at: t0)
        let item = makeItem()
        _ = try s.append(item, maxCount: Int.max)
        s.now = { t0.addingTimeInterval(50) }
        let deleted = try s.setDeletedAt(t0.addingTimeInterval(50), id: item.id)
        precondition(deleted.deletedAt == t0.addingTimeInterval(50))
        precondition(load(s, item.id).fieldClock!.stamp(for: .deletion) == t0.addingTimeInterval(50))
        s.now = { t0.addingTimeInterval(60) }
        let restored = try s.setDeletedAt(nil, id: item.id)
        precondition(restored.deletedAt == nil && load(s, item.id).deletedAt == nil)
        precondition(load(s, item.id).fieldClock!.stamp(for: .deletion) == t0.addingTimeInterval(60))
    }

    private static func testUpdateNeverClearsDeletedAt() throws {
        let s = store(at: t0)
        let item = makeItem()
        _ = try s.append(item, maxCount: Int.max)
        try s.setDeletedAt(t0, id: item.id)
        // A late title or summary save carries no deletion time.
        try s.update(makeItem(id: item.id, title: "Late title"))
        _ = try s.upsert(makeItem(id: item.id, title: "Later title"), maxCount: Int.max)
        precondition(load(s, item.id).deletedAt == t0, "a save never brings a deleted note back")
    }

    private static func testLoadIncludesDeletedRows() throws {
        let s = store(at: t0)
        let live = makeItem()
        let gone = makeItem()
        _ = try s.append(live, maxCount: Int.max)
        _ = try s.append(gone, maxCount: Int.max)
        try s.setDeletedAt(t0, id: gone.id)
        precondition(Set(s.loadAllHistory().map(\.id)) == [live.id, gone.id])
    }

    private static func testRowWithoutClockGetsTimestampClock() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("PipelineHistory.sqlite")
        let item = makeItem()
        do {
            let s = PipelineHistoryStore(storeURL: url)
            _ = try s.append(item, maxCount: Int.max)
            s.clearFieldClockForTesting(id: item.id)
        }
        let reopened = PipelineHistoryStore(storeURL: url)
        precondition(load(reopened, item.id).fieldClock == NoteFieldClock.uniform(t0))
    }

    /// A store written by a build without `deletedAt` and `fieldClockJSON`
    /// opens through lightweight migration and keeps its rows as live notes.
    private static func testStoreWithoutNewAttributesOpens() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("PipelineHistory.sqlite")
        let id = UUID()
        try PipelineHistoryStore.writeLegacyStoreForTesting(at: url, id: id, timestamp: t0)
        let s = PipelineHistoryStore(storeURL: url)
        precondition(s.availability == .ready)
        let row = load(s, id)
        precondition(row.deletedAt == nil)
        precondition(row.fieldClock == NoteFieldClock.uniform(t0))
    }

    /// Only a snapshot import keeps an item's deletion. An ordinary save of
    /// a stale copy (a late job finishing after Delete Now) never creates a
    /// row in Recently Deleted, and an existing row ignores the item's value.
    private static func testNewRowKeepsDeletionFromImportedItem() throws {
        let s = store(at: t0)
        func deletedItem() -> PipelineHistoryItem {
            PipelineHistoryItem(
                id: UUID(),
                timestamp: t0,
                rawTranscript: "synthetic raw",
                postProcessedTranscript: "synthetic edited",
                postProcessingPrompt: nil,
                contextSummary: "",
                contextScreenshotDataURL: nil,
                contextScreenshotStatus: "No screenshot",
                postProcessingStatus: "succeeded",
                debugStatus: "",
                customVocabulary: "",
                deletedAt: t0
            )
        }
        let imported = deletedItem()
        _ = try s.upsert(imported, maxCount: Int.max, keepsImportedDeletion: true)
        precondition(load(s, imported.id).deletedAt == t0, "a snapshot import keeps its deletion")
        let lateUpsert = deletedItem()
        _ = try s.upsert(lateUpsert, maxCount: Int.max)
        precondition(load(s, lateUpsert.id).deletedAt == nil, "an ordinary upsert never writes a deletion")
        let lateAppend = deletedItem()
        _ = try s.append(lateAppend, maxCount: Int.max)
        precondition(load(s, lateAppend.id).deletedAt == nil, "an ordinary append never writes a deletion")
        try s.setDeletedAt(nil, id: imported.id)
        _ = try s.upsert(imported, maxCount: Int.max, keepsImportedDeletion: true)
        precondition(load(s, imported.id).deletedAt == nil, "an existing row ignores an item's deletion")
    }
}
