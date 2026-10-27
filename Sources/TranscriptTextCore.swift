import Foundation
import os.log
import QuillProviderCore

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

/// The Mac's view of the shared cloud transcription parser. It keeps the Mac
/// options and logs why the hallucination filter was skipped.
enum TranscriptionResponseParser {
    static func parse(_ data: Data) throws -> ParsedTranscriptionResponse {
        try parsed { try CloudTranscriptionResponseParser.parse(data, options: .mac) }
    }

    static func parseJSONTranscript(_ data: Data) throws -> ParsedTranscriptionResponse {
        try parsed { try CloudTranscriptionResponseParser.parseJSON(data, options: .mac) }
    }

    private static func parsed(
        _ parse: () throws -> CloudTranscriptionResponseParser.Result
    ) throws -> ParsedTranscriptionResponse {
        let result: CloudTranscriptionResponseParser.Result
        do {
            result = try parse()
        } catch {
            throw TranscriptionResponseParsingError.invalidResponse
        }
        switch result.hallucinationFilterSkip {
        case .noSegments:
            os_log(
                .info,
                log: transcriptTextLog,
                "Skipping hallucination filter: provider response has no segments/no_speech metadata"
            )
        case .noNoSpeechProbability:
            os_log(
                .info,
                log: transcriptTextLog,
                "Skipping hallucination filter: provider response omitted no_speech_prob"
            )
        case nil:
            break
        }
        return ParsedTranscriptionResponse(
            text: result.response.text,
            engineLanguageCode: result.response.language
        )
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
