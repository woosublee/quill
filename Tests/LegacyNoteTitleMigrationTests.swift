import Foundation

@main
struct LegacyNoteTitleMigrationTests {
    static func main() throws {
        try testMigratesMatchingLegacyTitlesAndRemovesLegacyKeyAfterSuccessfulUpdates()
        try testRemovesLegacyKeyWhenOnlyStaleTitlesRemain()
        try testDuplicateLegacyUUIDKeysPreferCanonicalValue()
        try testDuplicateLegacyUUIDKeysUseSortedFallbackWhenCanonicalMissing()
        try testKeepsLegacyKeyWhenAnyUpdateFails()
        print("LegacyNoteTitleMigrationTests passed")
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

        assert(migrated.count == 1)
        assert(migrated[0].customTitle == "Migrated title")
        assert(updatedItems.map(\.id) == [migratedID])
        assert(updatedItems[0].customTitle == "Migrated title")
        assert(defaults.data(forKey: LegacyNoteTitleMigration.storageKey) == nil)
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

        assert(migrated.count == 1)
        assert(updatedItems.isEmpty)
        assert(defaults.data(forKey: LegacyNoteTitleMigration.storageKey) == nil)
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

        assert(migrated[0].customTitle == "Canonical title")
        assert(updatedItems.map(\.customTitle) == ["Canonical title"])
        assert(defaults.data(forKey: LegacyNoteTitleMigration.storageKey) == nil)
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

        assert(migrated[0].customTitle == "Mixedcase title")
        assert(updatedItems.map(\.customTitle) == ["Mixedcase title"])
        assert(defaults.data(forKey: LegacyNoteTitleMigration.storageKey) == nil)
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
            assertionFailure("Expected migration to throw when persistence fails")
        } catch {
            assert(defaults.data(forKey: LegacyNoteTitleMigration.storageKey) != nil)
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
