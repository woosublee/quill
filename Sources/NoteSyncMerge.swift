import Foundation

/// Merges two versions of one note group by group: the later stamp wins.
/// On a tie, the group whose encoded values sort higher wins, so every Mac
/// settles on the same values without knowing which Mac wrote them.
enum NoteSyncMerge {
    static func merge(local: NoteSyncRecord, remote: NoteSyncRecord) -> NoteSyncRecord {
        var local = local
        var remote = remote
        local.clock = local.clock.roundedToMilliseconds()
        remote.clock = remote.clock.roundedToMilliseconds()

        var merged = local
        for group in NoteFieldGroup.allCases {
            guard prefersRemote(group, local: local, remote: remote) else { continue }
            if group == .deletion {
                merged.deletedAt = remote.deletedAt
            } else {
                for field in NoteSyncField.allCases where field.group == group {
                    // A partial record never blanks a value every note has.
                    if field.isRequired, remote.fields[field.rawValue] == nil { continue }
                    merged.fields[field.rawValue] = remote.fields[field.rawValue]
                }
            }
            if let stamp = remote.clock.stamp(for: group) {
                merged.clock = merged.clock.setting(group, to: stamp)
            }
        }

        // Groups from a newer build: keep the later stamp of each.
        let knownGroups = Set(NoteFieldGroup.allCases.map(\.rawValue))
        var stamps = merged.clock.stamps
        for (group, stamp) in remote.clock.stamps where !knownGroups.contains(group) {
            stamps[group] = max(stamps[group] ?? .distantPast, stamp)
        }
        merged.clock = NoteFieldClock(stamps: stamps)

        // Keys from a newer build: the side edited most recently keeps its
        // value; on a tie, the higher value. Both Macs choose alike.
        let knownKeys = Set(NoteSyncField.allCases.map(\.rawValue) + [NoteSyncRecord.schemaVersionKey])
        let remoteIsNewer = latestStamp(remote) > latestStamp(local)
        let unknownKeys = Set(local.fields.keys).union(remote.fields.keys).subtracting(knownKeys)
        for key in unknownKeys {
            switch (local.fields[key], remote.fields[key]) {
            case (nil, let value?), (let value?, nil):
                merged.fields[key] = value
            case (let mine?, let theirs?):
                if latestStamp(remote) == latestStamp(local) {
                    merged.fields[key] = encodedText(theirs) > encodedText(mine) ? theirs : mine
                } else {
                    merged.fields[key] = remoteIsNewer ? theirs : mine
                }
            case (nil, nil):
                break
            }
        }

        // The schema version is the newest either side wrote.
        if case .int(let remoteVersion)? = remote.fields[NoteSyncRecord.schemaVersionKey],
           case .int(let localVersion)? = local.fields[NoteSyncRecord.schemaVersionKey],
           remoteVersion > localVersion {
            merged.fields[NoteSyncRecord.schemaVersionKey] = .int(remoteVersion)
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

    private static func latestStamp(_ record: NoteSyncRecord) -> Date {
        record.clock.stamps.values.max() ?? .distantPast
    }

    /// A stable text form of a group's values, for breaking ties.
    private static func signature(_ group: NoteFieldGroup, _ record: NoteSyncRecord) -> String {
        if group == .deletion {
            return record.deletedAt.map { String($0.timeIntervalSince1970) } ?? ""
        }
        return NoteSyncField.allCases
            .filter { $0.group == group }
            .map { field in
                "\(field.rawValue)=\(record.fields[field.rawValue].map(encodedText) ?? "-")"
            }
            .joined(separator: "|")
    }

    private static func encodedText(_ value: NoteSyncValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}
