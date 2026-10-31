import Foundation

/// The notices dismissed on a note, synced so a notice closed on one device
/// stays closed on every device (#730). The `dismissedNotices` field holds a
/// sorted JSON array of notice IDs. A notice, once dismissed, never comes
/// back: merges join both sides' sets.
public enum NoteDismissedNotices {
    /// "Nothing to clean up; showing the original transcript." Post-processing
    /// returned nothing to change.
    public static let nothingToCleanUp = "postProcessing.nothingToCleanUp"

    /// The IDs in a `dismissedNotices` value. Anything unreadable reads as
    /// none.
    public static func decode(_ value: NoteSyncValue?) -> Set<String> {
        guard case .data(let data)? = value,
              let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(ids)
    }

    /// The field value for a set of IDs, sorted so equal sets encode alike.
    public static func value(_ ids: Set<String>) -> NoteSyncValue {
        .data((try? JSONEncoder().encode(ids.sorted())) ?? Data("[]".utf8))
    }

    /// `fields` with `id` added to its dismissed notices.
    public static func adding(_ id: String, to fields: [String: NoteSyncValue]) -> [String: NoteSyncValue] {
        var fields = fields
        let key = NoteSyncField.dismissedNotices.rawValue
        fields[key] = value(decode(fields[key]).union([id]))
        return fields
    }
}
