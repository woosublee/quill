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
    public struct Options: Equatable, Sendable {
        /// Read each segment's start, end, and text. Only the iPhone uses them.
        public var readsSegments: Bool

        public init(readsSegments: Bool = false) {
            self.readsSegments = readsSegments
        }

        public static let mac = Options()
        public static let iPhone = Options(readsSegments: true)
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
            try validatePlainTextContent(text)
            return Result(
                response: CloudTranscriptionResponse(text: text, language: nil, segments: []),
                hallucinationFilterSkip: nil
            )
        }
        return try parseJSON(data, options: options)
    }

    /// A JSON reply only; plain text is rejected.
    public static func parseJSON(_ data: Data, options: Options = .mac) throws -> Result {
        guard let json = try decodedJSONObject(data) as? [String: Any],
              let text = json["text"] as? String else {
            throw CloudTranscriptionResponseParsingError.invalidResponse
        }
        let filter = hallucinationCheck(text: text, json: json)
        return Result(
            response: CloudTranscriptionResponse(
                text: filter.isHallucination ? "" : text,
                language: json["language"] as? String,
                segments: filter.isHallucination || !options.readsSegments ? [] : segments(from: json)
            ),
            hallucinationFilterSkip: filter.skip
        )
    }

    private static func decodedJSONObject(_ data: Data) throws -> Any {
        if let object = try? JSONSerialization.jsonObject(with: data) {
            return object
        }
        // Some providers write a metric such as `compression_ratio` as a bare
        // Infinity or NaN, which JSON doesn't allow. Read those as null rather
        // than failing the whole reply.
        guard let cleaned = nullingNonFiniteNumbers(in: data),
              let object = try? JSONSerialization.jsonObject(with: cleaned) else {
            throw CloudTranscriptionResponseParsingError.invalidResponse
        }
        return object
    }

    /// Replaces bare `NaN`, `Infinity`, and `-Infinity` outside JSON strings
    /// with `null`. Text inside strings is never touched, and every other byte
    /// is copied as is, so invalid UTF-8 still fails to decode. Returns nil
    /// when there is nothing to replace.
    private static func nullingNonFiniteNumbers(in data: Data) -> Data? {
        let bytes = Array(data)
        let tokens: [[UInt8]] = [Array("-Infinity".utf8), Array("Infinity".utf8), Array("NaN".utf8)]
        let null = Array("null".utf8)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var inString = false
        var escaped = false
        var replaced = false
        var index = 0
        func isWordByte(_ byte: UInt8) -> Bool {
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A)
                || (byte >= 0x61 && byte <= 0x7A) || byte == 0x5F || byte == 0x2E || byte == 0x2B || byte == 0x2D
        }
        while index < bytes.count {
            let byte = bytes[index]
            if inString {
                output.append(byte)
                if escaped {
                    escaped = false
                } else if byte == 0x5C {
                    escaped = true
                } else if byte == 0x22 {
                    inString = false
                }
                index += 1
                continue
            }
            if byte == 0x22 {
                inString = true
                output.append(byte)
                index += 1
                continue
            }
            // Only '-', 'I', or 'N' can start a token.
            let canStartToken = byte == 0x2D || byte == 0x49 || byte == 0x4E
            let startsWord = canStartToken && (index == 0 || !isWordByte(bytes[index - 1]))
            if startsWord, let token = tokens.first(where: { token in
                index + token.count <= bytes.count
                    && bytes[index..<(index + token.count)].elementsEqual(token)
                    && (index + token.count == bytes.count || !isWordByte(bytes[index + token.count]))
            }) {
                output.append(contentsOf: null)
                index += token.count
                replaced = true
                continue
            }
            output.append(byte)
            index += 1
        }
        return replaced ? Data(output) : nil
    }

    private static func segments(from json: [String: Any]) -> [CloudTranscriptionResponse.Segment] {
        guard let raw = json["segments"] as? [[String: Any]] else { return [] }
        return raw.compactMap { item in
            guard let start = jsonNumber(item["start"]),
                  let end = jsonNumber(item["end"]),
                  let text = item["text"] as? String,
                  start.isFinite, end.isFinite, end >= start else { return nil }
            return CloudTranscriptionResponse.Segment(start: start, end: end, text: text)
        }
    }

    /// A JSON number. JSON true and false also arrive as NSNumber; they
    /// aren't numbers.
    private static func jsonNumber(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        return number.doubleValue
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

    private static func validatePlainTextContent(_ text: String) throws {
        let byteOrderMark = CharacterSet(charactersIn: "\u{FEFF}")
        let contentOnly = text.trimmingCharacters(
            in: CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines).union(byteOrderMark)
        )
        guard !contentOnly.isEmpty else {
            throw CloudTranscriptionResponseParsingError.invalidResponse
        }
    }

    private static func hallucinationCheck(
        text: String,
        json: [String: Any]
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
        guard let noSpeechProb = jsonNumber(segments.first?["no_speech_prob"]),
              noSpeechProb.isFinite else {
            return (false, .noNoSpeechProbability)
        }
        return (noSpeechProb >= hallucinationNoSpeechThreshold, nil)
    }
}
