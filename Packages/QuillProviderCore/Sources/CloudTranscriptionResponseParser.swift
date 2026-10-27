import Foundation

public struct CloudTranscriptionResponse: Equatable, Sendable {
    public struct Segment: Equatable, Sendable {
        /// Seconds from the start of the uploaded audio.
        public let start: Double
        public let end: Double
        public let text: String

        public init(start: Double, end: Double, text: String) {
            self.start = start
            self.end = end
            self.text = text
        }
    }

    public let text: String
    public let language: String?
    /// Present only for `verbose_json`. The iPhone uses it to drop the overlap
    /// between chunks by time.
    public let segments: [Segment]

    public init(text: String, language: String?, segments: [Segment]) {
        self.text = text
        self.language = language
        self.segments = segments
    }
}

public enum CloudTranscriptionResponseParsingError: Error, Equatable, Sendable {
    case invalidResponse
}

/// Why the hallucination filter didn't run on a reply that matched one of its
/// phrases. The Mac logs it; the iPhone ignores it.
public enum CloudTranscriptionHallucinationFilterSkip: Equatable, Sendable {
    case noSegments
    case noNoSpeechProbability
}

/// Reads an OpenAI-compatible transcription reply: plain text, `json`, or
/// `verbose_json`. Whisper can answer silence with stock phrases such as
/// "thank you"; those are dropped only when the first segment reports a high
/// no-speech probability, which protects genuine short dictations.
public enum CloudTranscriptionResponseParser {
    /// The two apps still differ here (#651). The defaults are the Mac's.
    public struct Options: Equatable, Sendable {
        /// Replace bare `Infinity`, `-Infinity`, and `NaN` values with `null`
        /// before decoding instead of rejecting the reply. The iPhone does.
        public var acceptsNonFiniteNumbers: Bool
        /// Trim byte order marks from both ends of a plain-text reply before
        /// its empty check, instead of one leading mark. The iPhone does.
        public var trimsEveryByteOrderMark: Bool
        /// Read `no_speech_prob` from any JSON number, instead of only one that
        /// converts exactly to a Double. The iPhone does.
        public var readsAnyNumericNoSpeechProbability: Bool
        /// Read each segment's start, end, and text. Only the iPhone uses them.
        public var readsSegments: Bool

        public init(
            acceptsNonFiniteNumbers: Bool = false,
            trimsEveryByteOrderMark: Bool = false,
            readsAnyNumericNoSpeechProbability: Bool = false,
            readsSegments: Bool = false
        ) {
            self.acceptsNonFiniteNumbers = acceptsNonFiniteNumbers
            self.trimsEveryByteOrderMark = trimsEveryByteOrderMark
            self.readsAnyNumericNoSpeechProbability = readsAnyNumericNoSpeechProbability
            self.readsSegments = readsSegments
        }

        public static let mac = Options()
        public static let iPhone = Options(
            acceptsNonFiniteNumbers: true,
            trimsEveryByteOrderMark: true,
            readsAnyNumericNoSpeechProbability: true,
            readsSegments: true
        )
    }

    public struct Result: Equatable, Sendable {
        public let response: CloudTranscriptionResponse
        public let hallucinationFilterSkip: CloudTranscriptionHallucinationFilterSkip?

        public init(
            response: CloudTranscriptionResponse,
            hallucinationFilterSkip: CloudTranscriptionHallucinationFilterSkip?
        ) {
            self.response = response
            self.hallucinationFilterSkip = hallucinationFilterSkip
        }
    }

    private static let hallucinationPhrases: Set<String> = [
        "thank you",
        "thank you for watching",
        "thank you very much",
        "thank you so much",
        "thanks for watching",
        "please subscribe",
        "like and subscribe",
        "subtitles by",
        "subtitles by the amara.org community",
    ]

    // Tuned conservatively against roughly 500 quiet, noisy, and real-speech
    // samples to minimize the chance of filtering genuine short dictations.
    private static let hallucinationNoSpeechThreshold = 0.1

    private static let asciiLeftBrace: UInt8 = 0x7B
    private static let asciiLeftBracket: UInt8 = 0x5B
    private static let utf8BOM: [UInt8] = [0xEF, 0xBB, 0xBF]

    public static func parse(_ data: Data, options: Options = .mac) throws -> Result {
        guard let firstByte = firstSignificantByte(in: data) else {
            throw CloudTranscriptionResponseParsingError.invalidResponse
        }
        guard firstByte == asciiLeftBrace || firstByte == asciiLeftBracket else {
            guard let text = String(data: data, encoding: .utf8) else {
                throw CloudTranscriptionResponseParsingError.invalidResponse
            }
            try validatePlainTextContent(text, options: options)
            return Result(
                response: CloudTranscriptionResponse(text: text, language: nil, segments: []),
                hallucinationFilterSkip: nil
            )
        }
        return try parseJSON(data, options: options)
    }

    /// A JSON reply only; plain text is rejected.
    public static func parseJSON(_ data: Data, options: Options = .mac) throws -> Result {
        guard let json = try decodedJSONObject(data, options: options) as? [String: Any],
              let text = json["text"] as? String else {
            throw CloudTranscriptionResponseParsingError.invalidResponse
        }
        let filter = hallucinationCheck(text: text, json: json, options: options)
        return Result(
            response: CloudTranscriptionResponse(
                text: filter.isHallucination ? "" : text,
                language: json["language"] as? String,
                segments: filter.isHallucination || !options.readsSegments ? [] : segments(from: json)
            ),
            hallucinationFilterSkip: filter.skip
        )
    }

    private static func decodedJSONObject(_ data: Data, options: Options) throws -> Any {
        let source: Data
        if options.acceptsNonFiniteNumbers {
            let sanitized = String(decoding: data, as: UTF8.self).replacingOccurrences(
                of: #"(:\s*|,\s*|\[\s*)(-?Infinity|NaN)\b(?=\s*[,}\]])"#,
                with: "$1null",
                options: .regularExpression
            )
            source = Data(sanitized.utf8)
        } else {
            source = data
        }
        do {
            return try JSONSerialization.jsonObject(with: source)
        } catch {
            throw CloudTranscriptionResponseParsingError.invalidResponse
        }
    }

    private static func segments(from json: [String: Any]) -> [CloudTranscriptionResponse.Segment] {
        guard let raw = json["segments"] as? [[String: Any]] else { return [] }
        return raw.compactMap { item in
            guard let start = (item["start"] as? NSNumber)?.doubleValue,
                  let end = (item["end"] as? NSNumber)?.doubleValue,
                  let text = item["text"] as? String,
                  start.isFinite, end.isFinite, end >= start else { return nil }
            return CloudTranscriptionResponse.Segment(start: start, end: end, text: text)
        }
    }

    private static func firstSignificantByte(in data: Data) -> UInt8? {
        var index = data.startIndex
        if data.count >= utf8BOM.count, Array(data.prefix(utf8BOM.count)) == utf8BOM {
            index = data.index(index, offsetBy: utf8BOM.count)
        }
        while index < data.endIndex {
            let byte = data[index]
            if byte != 0x20 && byte != 0x09 && byte != 0x0A && byte != 0x0D {
                return byte
            }
            data.formIndex(after: &index)
        }
        return nil
    }

    private static func validatePlainTextContent(_ text: String, options: Options) throws {
        var candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if options.trimsEveryByteOrderMark {
            candidate = candidate.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
        } else if candidate.first == "\u{FEFF}" {
            candidate.removeFirst()
            candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let contentOnly = candidate.trimmingCharacters(
            in: CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines)
        )
        guard !contentOnly.isEmpty else {
            throw CloudTranscriptionResponseParsingError.invalidResponse
        }
    }

    private static func hallucinationCheck(
        text: String,
        json: [String: Any],
        options: Options
    ) -> (isHallucination: Bool, skip: CloudTranscriptionHallucinationFilterSkip?) {
        let normalized = text
            .lowercased()
            .trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines))
        guard hallucinationPhrases.contains(normalized) else {
            return (false, nil)
        }
        guard let segments = json["segments"] as? [[String: Any]] else {
            return (false, .noSegments)
        }
        let value = segments.first?["no_speech_prob"]
        let noSpeechProb = options.readsAnyNumericNoSpeechProbability
            ? (value as? NSNumber)?.doubleValue
            : value as? Double
        guard let noSpeechProb else {
            return (false, .noNoSpeechProbability)
        }
        return (noSpeechProb >= hallucinationNoSpeechThreshold, nil)
    }
}
