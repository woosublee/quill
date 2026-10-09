import Foundation

enum NoteSyncPayloadError: Error { case malformed }

/// The JSON a `Note` record carries as its `payload` asset. Shared with the
/// iPhone app, so keys never change once shipped; `v` versions the shape.
enum NoteSyncPayload {
    static let version = 1

    static func encode(_ record: NoteSyncRecord) throws -> Data {
        var object: [String: Any] = [
            "v": version,
            "id": record.noteID.uuidString,
            "fields": try fieldsObject(record.fields),
            "clock": record.clock.stamps.mapValues(milliseconds)
        ]
        if let deletedAt = record.deletedAt { object["deletedAt"] = milliseconds(deletedAt) }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func decode(_ data: Data) throws -> NoteSyncRecord {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let idText = object["id"] as? String, let noteID = UUID(uuidString: idText),
              let fieldsObject = object["fields"] as? [String: Any] else {
            throw NoteSyncPayloadError.malformed
        }
        var stamps: [String: Date] = [:]
        for (group, value) in object["clock"] as? [String: Any] ?? [:] {
            if let ms = (value as? NSNumber)?.doubleValue { stamps[group] = date(ms) }
        }
        return NoteSyncRecord(
            noteID: noteID,
            fields: try fields(from: fieldsObject),
            clock: NoteFieldClock(stamps: stamps),
            deletedAt: (object["deletedAt"] as? NSNumber).map { date($0.doubleValue) }
        )
    }

    static func encodeFields(_ fields: [String: NoteSyncValue]) throws -> Data {
        try JSONSerialization.data(withJSONObject: fieldsObject(fields), options: [.sortedKeys])
    }

    static func decodeFields(_ data: Data) throws -> [String: NoteSyncValue] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NoteSyncPayloadError.malformed
        }
        return try fields(from: object)
    }

    private static func fieldsObject(_ fields: [String: NoteSyncValue]) throws -> [String: Any] {
        try fields.mapValues { value -> Any in
            switch value {
            case .string(let text): return ["s": text]
            case .date(let date): return ["d": milliseconds(date)]
            case .bool(let flag): return ["b": flag]
            case .data(let data): return ["x": data.base64EncodedString()]
            case .int(let number): return ["i": number]
            case .raw(let json): return try JSONSerialization.jsonObject(with: json, options: [.fragmentsAllowed])
            }
        }
    }

    private static func fields(from object: [String: Any]) throws -> [String: NoteSyncValue] {
        var result: [String: NoteSyncValue] = [:]
        for (key, value) in object {
            if let value = known(value) {
                result[key] = value
            } else {
                result[key] = .raw(try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]))
            }
        }
        return result
    }

    private static func known(_ value: Any) -> NoteSyncValue? {
        guard let box = value as? [String: Any], box.count == 1, let (tag, inner) = box.first else { return nil }
        switch tag {
        case "s": return (inner as? String).map(NoteSyncValue.string)
        case "d": return (inner as? NSNumber).map { .date(date($0.doubleValue)) }
        case "b": return (inner as? NSNumber).flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? .bool($0.boolValue) : nil }
        case "x": return (inner as? String).flatMap { Data(base64Encoded: $0) }.map(NoteSyncValue.data)
        case "i": return (inner as? NSNumber).flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? nil : .int($0.intValue) }
        default: return nil
        }
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    private static func date(_ milliseconds: Double) -> Date {
        Date(timeIntervalSince1970: milliseconds / 1000)
    }
}
