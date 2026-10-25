import Foundation

public struct AIProcessingEnvelope<Payload: Encodable & Sendable>: Encodable, Sendable {
    public let contractVersion: String
    public let feature: String
    public let data: Payload

    public init(contractVersion: String, feature: String, data: Payload) {
        self.contractVersion = contractVersion
        self.feature = feature
        self.data = data
    }

    public func encodedJSONString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting.insert(.sortedKeys)
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

public struct PostProcessingSourceData: Codable, Equatable, Sendable {
    public let transcript: String
    public let contextSummary: String
    public let vocabulary: [String]
    public var corrections: [VocabularyCorrection]? = nil

    public init(
        transcript: String,
        contextSummary: String,
        vocabulary: [String],
        corrections: [VocabularyCorrection]? = nil
    ) {
        self.transcript = transcript
        self.contextSummary = contextSummary
        self.vocabulary = vocabulary
        self.corrections = corrections
    }
}

/// One explicit mishearing correction from custom vocabulary:
/// `heard -> correct`.
public struct VocabularyCorrection: Codable, Equatable, Sendable {
    public let heard: String
    public let correct: String

    public init(heard: String, correct: String) {
        self.heard = heard
        self.correct = correct
    }
}
