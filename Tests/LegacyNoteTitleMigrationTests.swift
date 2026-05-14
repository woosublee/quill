import Foundation

@main
struct LegacyNoteTitleMigrationTests {
    enum TestError: Error {
        case failed(String)
    }

    static func main() throws {
        try testMigratesMatchingLegacyTitlesAndRemovesLegacyKeyAfterSuccessfulUpdates()
        try testRemovesLegacyKeyWhenOnlyStaleTitlesRemain()
        try testDuplicateLegacyUUIDKeysPreferCanonicalValue()
        try testDuplicateLegacyUUIDKeysUseSortedFallbackWhenCanonicalMissing()
        try testKeepsLegacyKeyWhenAnyUpdateFails()
        print("LegacyNoteTitleMigrationTests passed")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() {
            throw TestError.failed(message)
        }
    }

    private static func testMigratesMatchingLegacyTitlesAndRemovesLegacyKeyAfterSuccessfulUpdates() throws {
        let defaults = makeDefaults()
        let migratedID = UUID(uuidString: "00000000-0000-0000-0000-000000000083")!
        let staleID = UUID(uuidString: "00000000-0000-0000-0000-000000000084")!
        storeLegacyTitles([
            migratedID: "  Migrated title  ",
            staleID: "Deleted note title"
        ], defaults: defaults)
        let history = [historyItem(id: migratedID, transcript: "Transcript title")]
        var updatedItems: [PipelineHistoryItem] = []

        let migrated = try LegacyNoteTitleMigration.migrate(
            history: history,
            defaults: defaults,
            update: { updatedItems.append($0) }
        )

        try require(migrated.count == 1, "Expected one migrated history item")
        try require(migrated[0].customTitle == "Migrated title", "Expected trimmed migrated title")
        try require(updatedItems.map(\.id) == [migratedID], "Expected only the matching item to persist")
        try require(updatedItems[0].customTitle == "Migrated title", "Expected persisted title to be trimmed")
        try require(defaults.data(forKey: LegacyNoteTitleMigration.storageKey) == nil, "Expected successful migration to remove legacy key")
    }

    private static func testRemovesLegacyKeyWhenOnlyStaleTitlesRemain() throws {
        let defaults = makeDefaults()
        let staleID = UUID(uuidString: "00000000-0000-0000-0000-000000000086")!
        storeLegacyTitles([staleID: "Deleted note title"], defaults: defaults)
        let history = [historyItem(id: UUID(uuidString: "00000000-0000-0000-0000-000000000087")!, transcript: "Transcript title")]
        var updatedItems: [PipelineHistoryItem] = []

        let migrated = try LegacyNoteTitleMigration.migrate(
            history: history,
            defaults: defaults,
            update: { updatedItems.append($0) }
        )

        try require(migrated.count == 1, "Expected stale-only migration to preserve history")
        try require(updatedItems.isEmpty, "Expected no persisted updates for stale legacy titles")
        try require(defaults.data(forKey: LegacyNoteTitleMigration.storageKey) == nil, "Expected stale-only migration to remove legacy key")
    }

    private static func testDuplicateLegacyUUIDKeysPreferCanonicalValue() throws {
        let defaults = makeDefaults()
        let id = UUID(uuidString: "550E8400-E29B-41D4-A716-446655440000")!
        storeRawLegacyTitles([
            id.uuidString: "Canonical title",
            id.uuidString.lowercased(): "Lowercase title"
        ], defaults: defaults)
        let history = [historyItem(id: id, transcript: "Transcript title")]
        var updatedItems: [PipelineHistoryItem] = []

        let migrated = try LegacyNoteTitleMigration.migrate(
            history: history,
            defaults: defaults,
            update: { updatedItems.append($0) }
        )

        try require(migrated[0].customTitle == "Canonical title", "Expected canonical UUID key to win")
        try require(updatedItems.map(\.customTitle) == ["Canonical title"], "Expected canonical title to persist")
        try require(defaults.data(forKey: LegacyNoteTitleMigration.storageKey) == nil, "Expected duplicate-key migration to remove legacy key")
    }

    private static func testDuplicateLegacyUUIDKeysUseSortedFallbackWhenCanonicalMissing() throws {
        let defaults = makeDefaults()
        let id = UUID(uuidString: "550E8400-E29B-41D4-A716-446655440001")!
        storeRawLegacyTitles([
            id.uuidString.lowercased(): "Lowercase title",
            "550E8400-e29b-41d4-a716-446655440001": "Mixedcase title"
        ], defaults: defaults)
        let history = [historyItem(id: id, transcript: "Transcript title")]
        var updatedItems: [PipelineHistoryItem] = []

        let migrated = try LegacyNoteTitleMigration.migrate(
            history: history,
            defaults: defaults,
            update: { updatedItems.append($0) }
        )

        try require(migrated[0].customTitle == "Mixedcase title", "Expected sorted duplicate-key fallback title")
        try require(updatedItems.map(\.customTitle) == ["Mixedcase title"], "Expected fallback title to persist")
        try require(defaults.data(forKey: LegacyNoteTitleMigration.storageKey) == nil, "Expected fallback duplicate-key migration to remove legacy key")
    }

    private static func testKeepsLegacyKeyWhenAnyUpdateFails() throws {
        let defaults = makeDefaults()
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000085")!
        storeLegacyTitles([id: "Migrated title"], defaults: defaults)
        let history = [historyItem(id: id, transcript: "Transcript title")]

        do {
            _ = try LegacyNoteTitleMigration.migrate(
                history: history,
                defaults: defaults,
                update: { _ in throw NSError(domain: "LegacyNoteTitleMigrationTests", code: 1) }
            )
            throw TestError.failed("Expected migration to throw when persistence fails")
        } catch let error as TestError {
            throw error
        } catch {
            try require(defaults.data(forKey: LegacyNoteTitleMigration.storageKey) != nil, "Expected failed migration to keep legacy key")
        }
    }

    private static func makeDefaults() -> UserDefaults {
        let suiteName = "LegacyNoteTitleMigrationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private static func storeLegacyTitles(_ titles: [UUID: String], defaults: UserDefaults) {
        let raw = Dictionary(uniqueKeysWithValues: titles.map { ($0.key.uuidString, $0.value) })
        storeRawLegacyTitles(raw, defaults: defaults)
    }

    private static func storeRawLegacyTitles(_ titles: [String: String], defaults: UserDefaults) {
        let data = try! JSONEncoder().encode(titles)
        defaults.set(data, forKey: LegacyNoteTitleMigration.storageKey)
    }

    private static func historyItem(id: UUID, transcript: String, customTitle: String? = nil) -> PipelineHistoryItem {
        PipelineHistoryItem(
            id: id,
            timestamp: Date(timeIntervalSince1970: 1),
            rawTranscript: transcript,
            postProcessedTranscript: transcript,
            postProcessingPrompt: nil,
            contextSummary: "",
            contextPrompt: nil,
            contextScreenshotDataURL: nil,
            contextScreenshotStatus: "No screenshot",
            postProcessingStatus: "Post-processing succeeded",
            debugStatus: "Done",
            customVocabulary: "",
            customTitle: customTitle
        )
    }
}
