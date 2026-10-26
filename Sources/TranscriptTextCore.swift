import Foundation
import os.log

private let transcriptTextLog = OSLog(
    subsystem: "com.woosublee.quill",
    category: "Transcription"
)

struct ParsedTranscriptionResponse: Equatable, Sendable {
    let text: String
    let engineLanguageCode: String?
}

enum TranscriptionResponseParsingError: Error, Equatable {
    case invalidResponse
}

enum TranscriptionResponseParser {
    // Whisper can emit these stock phrases for silence or background noise.
    // Only suppress them when segment metadata independently reports a high
    // probability of no speech, which protects genuine short dictations.
    private static let hallucinationPhrases: Set<String> = [
        "thank you",
        "thank you for watching",
        "thank you very much",
        "thank you so much",
        "thanks for watching",
        "please subscribe",
        "like and subscribe",
        "subtitles by",
        "subtitles by the amara.org community"
    ]

    // Tuned conservatively against roughly 500 quiet, noisy, and real-speech
    // samples to minimize the chance of filtering genuine short dictations.
    private static let hallucinationNoSpeechThreshold = 0.1

    static func parse(_ data: Data) throws -> ParsedTranscriptionResponse {
        guard let firstByte = firstSignificantByte(in: data) else {
            throw TranscriptionResponseParsingError.invalidResponse
        }

        guard firstByte == asciiLeftBrace || firstByte == asciiLeftBracket else {
            let plainText = try decodedPlainText(data)
            try validatePlainTextContent(plainText)
            return ParsedTranscriptionResponse(
                text: plainText,
                engineLanguageCode: nil
            )
        }

        let object = try decodedJSONObject(data)
        guard let response = parsedTranscript(from: object) else {
            throw TranscriptionResponseParsingError.invalidResponse
        }
        return response
    }

    static func parseJSONTranscript(_ data: Data) throws -> ParsedTranscriptionResponse {
        let object = try decodedJSONObject(data)
        guard let response = parsedTranscript(from: object) else {
            throw TranscriptionResponseParsingError.invalidResponse
        }
        return response
    }

    private static let asciiLeftBrace: UInt8 = 0x7B
    private static let asciiLeftBracket: UInt8 = 0x5B
    private static let utf8BOM: [UInt8] = [0xEF, 0xBB, 0xBF]

    private static func firstSignificantByte(in data: Data) -> UInt8? {
        var index = data.startIndex
        if data.count >= utf8BOM.count,
           Array(data.prefix(utf8BOM.count)) == utf8BOM {
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

    private static func decodedJSONObject(_ data: Data) throws -> Any {
        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            throw TranscriptionResponseParsingError.invalidResponse
        }
    }

    private static func parsedTranscript(from object: Any) -> ParsedTranscriptionResponse? {
        guard let json = object as? [String: Any],
              let text = json["text"] as? String else {
            return nil
        }
        return ParsedTranscriptionResponse(
            text: isHallucination(text: text, json: json) ? "" : text,
            engineLanguageCode: json["language"] as? String
        )
    }

    private static func decodedPlainText(_ data: Data) throws -> String {
        guard let text = String(data: data, encoding: .utf8) else {
            throw TranscriptionResponseParsingError.invalidResponse
        }
        return text
    }

    private static func normalizedCandidate(_ text: String) -> String {
        var candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.first == "\u{FEFF}" {
            candidate.removeFirst()
            candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return candidate
    }

    private static func validatePlainTextContent(_ text: String) throws {
        let candidate = normalizedCandidate(text)
        let contentOnly = candidate.trimmingCharacters(
            in: CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines)
        )
        guard !contentOnly.isEmpty else {
            throw TranscriptionResponseParsingError.invalidResponse
        }
    }

    private static func isHallucination(text: String, json: [String: Any]) -> Bool {
        let normalized = text
            .lowercased()
            .trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines))
        guard hallucinationPhrases.contains(normalized) else {
            return false
        }

        guard let segments = json["segments"] as? [[String: Any]] else {
            os_log(
                .info,
                log: transcriptTextLog,
                "Skipping hallucination filter: provider response has no segments/no_speech metadata"
            )
            return false
        }

        guard let noSpeechProb = segments.first?["no_speech_prob"] as? Double else {
            os_log(
                .info,
                log: transcriptTextLog,
                "Skipping hallucination filter: provider response omitted no_speech_prob"
            )
            return false
        }
        return noSpeechProb >= hallucinationNoSpeechThreshold
    }
}

enum TranscriptOutputSanitizer {
    // Verbatim translation deliberately preserves the cleanup prompt's EMPTY
    // sentinel because "empty" can be legitimate translated speech here.
    static func verbatimTranslation(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return "" }
        if result.hasPrefix("\"") && result.hasSuffix("\"") && result.count > 1 {
            result.removeFirst()
            result.removeLast()
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    static func commandModeTranscript(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
