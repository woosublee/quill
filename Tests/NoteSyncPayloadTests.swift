import Foundation

@main
struct NoteSyncPayloadTests {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    static func main() throws {
        try testRoundTrip()
        try testUnknownValueShapesSurvive()
        testMalformedPayloadIsRejected()
        try testFieldsAloneRoundTrip()
        print("NoteSyncPayloadTests passed")
    }

    static func record() -> NoteSyncRecord {
        NoteSyncRecord(
            noteID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            fields: [
                "customTitle": .string("Synthetic title"),
                "timestamp": .date(t0),
                "usedPostProcessing": .bool(true),
                "meetingSummaryJSON": .data(Data("{\"a\":1}".utf8)),
                NoteSyncRecord.schemaVersionKey: .int(1)
            ],
            // Records carry millisecond clocks (`NoteSyncRecord(item:)` rounds them).
            clock: NoteFieldClock.uniform(t0.addingTimeInterval(0.123)).roundedToMilliseconds(),
            deletedAt: t0.addingTimeInterval(5)
        )
    }

    static func testRoundTrip() throws {
        let original = record()
        let decoded = try NoteSyncPayload.decode(NoteSyncPayload.encode(original))
        precondition(decoded == original, "payload round trip keeps every field")
    }

    static func testUnknownValueShapesSurvive() throws {
        var json = try JSONSerialization.jsonObject(with: NoteSyncPayload.encode(record())) as! [String: Any]
        var fields = json["fields"] as! [String: Any]
        fields["futureList"] = ["l": [1, 2, 3]]
        json["fields"] = fields
        let decoded = try NoteSyncPayload.decode(JSONSerialization.data(withJSONObject: json))
        guard case .raw(let raw)? = decoded.fields["futureList"] else {
            preconditionFailure("an unknown value shape is kept as raw JSON")
        }
        let reencoded = try JSONSerialization.jsonObject(with: NoteSyncPayload.encode(decoded)) as! [String: Any]
        let kept = (reencoded["fields"] as! [String: Any])["futureList"] as! [String: Any]
        precondition((kept["l"] as! [Int]) == [1, 2, 3], "raw values are written back unchanged")
        precondition(decoded.fields["customTitle"] == .string("Synthetic title"), "known fields still decode")
        precondition(!raw.isEmpty)
    }

    static func testMalformedPayloadIsRejected() {
        for bad in ["[]", "{}", "{\"v\":1,\"id\":\"not-a-uuid\",\"fields\":{}}", "not json"] {
            do {
                _ = try NoteSyncPayload.decode(Data(bad.utf8))
                preconditionFailure("malformed payload \(bad) must throw")
            } catch {}
        }
    }

    static func testFieldsAloneRoundTrip() throws {
        let fields: [String: NoteSyncValue] = ["futureField": .string("kept"), "n": .int(3)]
        let decoded = try NoteSyncPayload.decodeFields(NoteSyncPayload.encodeFields(fields))
        precondition(decoded == fields)
    }
}
