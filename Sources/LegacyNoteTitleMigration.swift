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
        defaults.removeObject(forKey: storageKey)
        return migratedHistory
    }

    private static func loadLegacyTitles(from defaults: UserDefaults) -> [UUID: String]? {
        guard let data = defaults.data(forKey: storageKey),
              let raw = try? JSONDecoder().decode([String: String].self, from: data) else {
            return nil
        }
        var titlesByID: [UUID: [(key: String, value: String)]] = [:]
        for (key, value) in raw {
            guard let id = UUID(uuidString: key) else { continue }
            titlesByID[id, default: []].append((key, value))
        }

        return Dictionary(uniqueKeysWithValues: titlesByID.map { id, titles in
            let selected = titles.first(where: { $0.key == id.uuidString })
                ?? titles.min { $0.key < $1.key }!
            return (id, selected.value)
        })
    }
}
