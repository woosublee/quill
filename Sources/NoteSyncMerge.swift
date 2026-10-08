import Foundation

/// Merges two versions of one note group by group: the later stamp wins.
/// On a tie, the group whose encoded values sort higher wins, so every Mac
/// settles on the same values without knowing which Mac wrote them.
enum NoteSyncMerge {
    static func merge(local: NoteSyncRecord, remote: NoteSyncRecord) -> NoteSyncRecord {
        var merged = local
        for group in NoteFieldGroup.allCases {
            guard prefersRemote(group, local: local, remote: remote) else { continue }
            if group == .deletion {
                merged.deletedAt = remote.deletedAt
            } else {
                for field in NoteSyncField.allCases where field.group == group {
                    merged.fields[field.rawValue] = remote.fields[field.rawValue]
                }
            }
            if let stamp = remote.clock.stamp(for: group) {
                merged.clock = merged.clock.setting(group, to: stamp)
            }
        }
        // Keys this build doesn't know: keep both sides', remote's value on a clash.
        let known = Set(NoteSyncField.allCases.map(\.rawValue))
        for (key, value) in remote.fields where !known.contains(key) {
            merged.fields[key] = value
        }
        return merged
    }

    private static func prefersRemote(
        _ group: NoteFieldGroup,
        local: NoteSyncRecord,
        remote: NoteSyncRecord
    ) -> Bool {
        let localStamp = local.clock.stamp(for: group) ?? .distantPast
        let remoteStamp = remote.clock.stamp(for: group) ?? .distantPast
        if remoteStamp != localStamp { return remoteStamp > localStamp }
        return signature(group, remote) > signature(group, local)
    }

    /// A stable text form of a group's values, for breaking ties.
    private static func signature(_ group: NoteFieldGroup, _ record: NoteSyncRecord) -> String {
        if group == .deletion {
            return record.deletedAt.map { String($0.timeIntervalSince1970) } ?? ""
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return NoteSyncField.allCases
            .filter { $0.group == group }
            .map { field in
                let value = record.fields[field.rawValue]
                let text = value.flatMap { try? encoder.encode($0) }
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "-"
                return "\(field.rawValue)=\(text)"
            }
            .joined(separator: "|")
    }
}
