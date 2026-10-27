import Foundation

public enum NoteSyncPayloadError: Error, Sendable { case malformed }

/// The JSON a `Note` record carries as its `payload` asset. Shared with the
/// iPhone app, so keys never change once shipped; `v` versions the shape.
public enum NoteSyncPayload {
    public static let version = 1

    public static func encode(_ record: NoteSyncRecord) throws -> Data {
        var object: [String: Any] = [
            "v": version,
            "id": record.noteID.uuidString,
            "fields": try fieldsObject(record.fields),
            "clock": record.clock.stamps.mapValues(milliseconds)
        ]
        if let deletedAt = record.deletedAt { object["deletedAt"] = milliseconds(deletedAt) }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    public static func decode(_ data: Data) throws -> NoteSyncRecord {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let idText = object["id"] as? String, let noteID = UUID(uuidString: idText),
              let fieldsObject = object["fields"] as? [String: Any] else {
            throw NoteSyncPayloadError.malformed
        }
        var stamps: [String: Date] = [:]
        for (group, value) in object["clock"] as? [String: Any] ?? [:] {
            // A boolean where a time belongs means the payload is damaged; a
            // record that dropped it could undo a deletion when merged (#673).
            guard !isBoolean(value) else { throw NoteSyncPayloadError.malformed }
            if let ms = number(value) { stamps[group] = date(ms) }
        }
        guard !isBoolean(object["deletedAt"]) else { throw NoteSyncPayloadError.malformed }
        return NoteSyncRecord(
            noteID: noteID,
            fields: try fields(from: fieldsObject),
            clock: NoteFieldClock(stamps: stamps),
            deletedAt: number(object["deletedAt"]).map(date)
        )
    }

    public static func encodeFields(_ fields: [String: NoteSyncValue]) throws -> Data {
        try JSONSerialization.data(withJSONObject: fieldsObject(fields), options: [.sortedKeys])
    }

    public static func decodeFields(_ data: Data) throws -> [String: NoteSyncValue] {
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
        case "d": return number(inner).map { .date(date($0)) }
        case "b": return (inner as? NSNumber).flatMap { isBoolean($0) ? .bool($0.boolValue) : nil }
        case "x": return (inner as? String).flatMap { Data(base64Encoded: $0) }.map(NoteSyncValue.data)
        case "i": return number(inner).flatMap(exactInteger).map(NoteSyncValue.int)
        default: return nil
        }
    }

    /// Only a whole number that fits an `Int` reads as one; anything else is
    /// kept as raw JSON rather than changed.
    private static func exactInteger(_ value: Double) -> Int? {
        guard value == value.rounded(), abs(value) < 9_007_199_254_740_992 else { return nil }
        return Int(exactly: value)
    }

    /// A JSON number. JSON true and false also arrive as NSNumber; they
    /// aren't numbers (#673).
    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, !isBoolean(number) else { return nil }
        return number.doubleValue
    }

    private static func isBoolean(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    private static func date(_ milliseconds: Double) -> Date {
        Date(timeIntervalSince1970: milliseconds / 1000)
    }
}
