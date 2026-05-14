import Foundation

enum LegacyNoteTitleMigration {
    static let storageKey = "note_custom_titles"

    static func migrate(
        history: [PipelineHistoryItem],
        defaults: UserDefaults = .standard,
        update: (PipelineHistoryItem) throws -> Void
    ) throws -> [PipelineHistoryItem] {
        guard let legacyTitles = loadLegacyTitles(from: defaults), !legacyTitles.isEmpty else {
            return history
        }

        var migratedHistory = history
        var updatedItems: [PipelineHistoryItem] = []
        for index in migratedHistory.indices {
            let item = migratedHistory[index]
            guard item.customTitle == nil,
                  let legacyTitle = legacyTitles[item.id] else { continue }
            let trimmedTitle = legacyTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedTitle.isEmpty else { continue }
            let updated = item.withCustomTitle(trimmedTitle)
            migratedHistory[index] = updated
            updatedItems.append(updated)
        }

        for item in updatedItems {
            try update(item)
        }
        if !updatedItems.isEmpty {
            defaults.removeObject(forKey: storageKey)
        }
        return migratedHistory
    }

    private static func loadLegacyTitles(from defaults: UserDefaults) -> [UUID: String]? {
        guard let data = defaults.data(forKey: storageKey),
              let raw = try? JSONDecoder().decode([String: String].self, from: data) else {
            return nil
        }
        return Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in
            guard let id = UUID(uuidString: key) else { return nil }
            return (id, value)
        })
    }
}
