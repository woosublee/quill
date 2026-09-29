import Foundation

struct AIProcessingEnvelope<Payload: Encodable & Sendable>: Encodable, Sendable {
    let contractVersion: String
    let feature: String
    let data: Payload

    func encodedJSONString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting.insert(.sortedKeys)
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

struct PostProcessingSourceData: Codable, Equatable, Sendable {
    let transcript: String
    let contextSummary: String
    let vocabulary: [String]
    var corrections: [VocabularyCorrection]? = nil
}

/// One explicit mishearing correction from custom vocabulary:
/// `heard -> correct`.
struct VocabularyCorrection: Codable, Equatable, Sendable {
    let heard: String
    let correct: String
}

struct SummarySourceData: Codable, Equatable, Sendable {
    let transcript: String
    let calendar: MeetingSummaryCalendarContext?
}
