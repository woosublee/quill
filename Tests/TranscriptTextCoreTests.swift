import Foundation
import QuillAITextCore
import QuillProviderCore

@main
struct TranscriptTextCoreTests {
    static func main() {
        testJSONTranscriptAndLanguageParsing()
        testPlainTextProviderResponseIsPreserved()
        testJSONWithoutTextIsRejected()
        testMalformedJSONLikeResponsesAreRejected()
        testOrdinaryTextContainingBracesIsPreserved()
        testInvalidTranscriptResponses()
        testHighConfidenceHallucinationsAreSuppressed()
        testPossibleRealSpeechIsPreserved()
        testSharedParserKeepsEachAppsOptions()
        testPostProcessedTranscriptSanitization()
        testModeSpecificSanitization()
        print("TranscriptTextCoreTests passed")
    }

    private static func testJSONTranscriptAndLanguageParsing() {
        let data = jsonData(["text": " Synthetic transcript. ", "language": "ko"])
        expectEqual(
            try? TranscriptionResponseParser.parse(data),
            Optional(
                ParsedTranscriptionResponse(
                    text: " Synthetic transcript. ",
                    engineLanguageCode: "ko"
                )
            )
        )

        var bomData = Data([0xEF, 0xBB, 0xBF])
        bomData.append(data)
        expectEqual(
            try? TranscriptionResponseParser.parse(bomData),
            Optional(
                ParsedTranscriptionResponse(
                    text: " Synthetic transcript. ",
                    engineLanguageCode: "ko"
                )
            )
        )

        let emptyData = jsonData(["text": ""])
        expectEqual(
            try? TranscriptionResponseParser.parse(emptyData),
            Optional(ParsedTranscriptionResponse(text: "", engineLanguageCode: nil))
        )
    }

    private static func testPlainTextProviderResponseIsPreserved() {
        let parsed = try? TranscriptionResponseParser.parse(
            Data("  first line\nsecond line  ".utf8)
        )
        expectEqual(parsed?.engineLanguageCode, nil as String?)
        expectEqual(
            parsed.map { TranscriptTextNormalizer.normalized($0.text) },
            Optional("first line second line")
        )
    }

    private static func testJSONWithoutTextIsRejected() {
        expectInvalidResponse(Data("{\"error\":\"upstream unavailable\"}".utf8))
        expectInvalidResponse(Data("[\"unexpected\"]".utf8))
        expectInvalidResponse(Data("{}".utf8))
        expectInvalidResponse(Data("[]".utf8))
    }

    private static func testMalformedJSONLikeResponsesAreRejected() {
        expectInvalidResponse(Data("{malformed synthetic JSON".utf8))
        expectInvalidResponse(Data("[malformed synthetic JSON".utf8))
        expectInvalidResponse(Data("\u{FEFF}  {malformed synthetic JSON".utf8))
    }

    private static func testOrdinaryTextContainingBracesIsPreserved() {
        let parsed = try? TranscriptionResponseParser.parse(
            Data("Say {hello} literally.".utf8)
        )
        expectEqual(parsed?.text, "Say {hello} literally.")
    }

    private static func testInvalidTranscriptResponses() {
        expectInvalidResponse(Data())
        expectInvalidResponse(Data(" \n\t ".utf8))
        expectInvalidResponse(Data("...?!".utf8))
        expectInvalidResponse(Data([0xFF, 0xFE]))
    }

    private static func testHighConfidenceHallucinationsAreSuppressed() {
        let atThreshold = jsonData([
            "text": "Thank you.",
            "segments": [["no_speech_prob": 0.1]]
        ])
        expectEqual(
            (try? TranscriptionResponseParser.parse(atThreshold))?.text,
            Optional("")
        )

        let normalizedPhrase = jsonData([
            "text": "  THANK YOU FOR WATCHING!!!  ",
            "segments": [["no_speech_prob": 0.9]]
        ])
        expectEqual(
            (try? TranscriptionResponseParser.parse(normalizedPhrase))?.text,
            Optional("")
        )

    }

    private static func testPossibleRealSpeechIsPreserved() {
        let lowProbability = jsonData([
            "text": "Thank you.",
            "segments": [["no_speech_prob": 0.099]]
        ])
        expectEqual(
            (try? TranscriptionResponseParser.parse(lowProbability))?.text,
            Optional("Thank you.")
        )

        let shortPhrase = jsonData([
            "text": "You.",
            "segments": [["no_speech_prob": 0.9]]
        ])
        expectEqual(
            (try? TranscriptionResponseParser.parse(shortPhrase))?.text,
            Optional("You.")
        )

        let missingMetadata = jsonData(["text": "Thank you."])
        expectEqual(
            (try? TranscriptionResponseParser.parse(missingMetadata))?.text,
            Optional("Thank you.")
        )

        let missingProbability = jsonData([
            "text": "Thank you.",
            "segments": [["synthetic": true]]
        ])
        expectEqual(
            (try? TranscriptionResponseParser.parse(missingProbability))?.text,
            Optional("Thank you.")
        )

        let unrelatedSpeech = jsonData([
            "text": "Synthetic project update.",
            "segments": [["no_speech_prob": 0.95]]
        ])
        expectEqual(
            (try? TranscriptionResponseParser.parse(unrelatedSpeech))?.text,
            Optional("Synthetic project update.")
        )
    }

    private static func testPostProcessedTranscriptSanitization() {
        expectEqual(
            PostProcessingReplySanitizer.postProcessedTranscript("  \"Synthetic output.\" \n"),
            "Synthetic output."
        )
        expectEqual(PostProcessingReplySanitizer.postProcessedTranscript("EMPTY"), "")
        expectEqual(PostProcessingReplySanitizer.postProcessedTranscript("\"EMPTY\""), "")
        expectEqual(PostProcessingReplySanitizer.postProcessedTranscript("empty"), "empty")
        expectEqual(PostProcessingReplySanitizer.postProcessedTranscript("  \n "), "")
    }

    private static func testModeSpecificSanitization() {
        expectEqual(
            TranscriptOutputSanitizer.verbatimTranslation("  \"EMPTY\"  "),
            "EMPTY"
        )
        expectEqual(
            TranscriptOutputSanitizer.verbatimTranslation(" \"Literal synthetic text.\" "),
            "Literal synthetic text."
        )
        expectEqual(
            TranscriptOutputSanitizer.commandModeTranscript("  \"Keep command quotes\" \n"),
            "\"Keep command quotes\""
        )
    }

    private static func jsonData(_ object: [String: Any]) -> Data {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else {
            fatalError("Synthetic JSON fixture should be serializable")
        }
        return data
    }

    // The two apps still differ here (#651): the iPhone accepts non-finite
    // numbers and trims byte order marks from both ends; the Mac does neither.
    private static func testSharedParserKeepsEachAppsOptions() {
        let nonFinite = Data(#"{"text":"We ship on Friday.","segments":[{"start":0,"end":1.5,"text":"We ship on Friday.","compression_ratio":Infinity,"no_speech_prob":0.01}]}"#.utf8)
        expectInvalidResponse(nonFinite)
        let iPhone = try? CloudTranscriptionResponseParser.parse(nonFinite, options: .iPhone)
        expectEqual(iPhone?.response.text, "We ship on Friday.")
        expectEqual(iPhone?.response.segments, [.init(start: 0, end: 1.5, text: "We ship on Friday.")])

        // Punctuation followed by a byte order mark: the Mac keeps the mark as
        // content, the iPhone trims it and finds nothing left.
        let markOnly = Data(".\u{FEFF}".utf8)
        expectEqual(
            (try? CloudTranscriptionResponseParser.parse(markOnly, options: .mac))?.response.text,
            ".\u{FEFF}"
        )
        expectEqual((try? CloudTranscriptionResponseParser.parse(markOnly, options: .iPhone))?.response.text, nil)

        let silence = Data(#"{"text":"Thank you.","segments":[{"start":0,"end":1,"text":"Thank you.","no_speech_prob":0.6}]}"#.utf8)
        for options in [CloudTranscriptionResponseParser.Options.mac, .iPhone] {
            let result = try? CloudTranscriptionResponseParser.parse(silence, options: options)
            expectEqual(result?.response.text, "")
            expectEqual(result?.response.segments, [])
        }
        let noMetadata = Data(#"{"text":"Thank you."}"#.utf8)
        expectEqual(
            (try? CloudTranscriptionResponseParser.parse(noMetadata))?.hallucinationFilterSkip,
            .noSegments
        )
        let noProbability = Data(#"{"text":"Thank you.","segments":[{"start":0,"end":1,"text":"Thank you."}]}"#.utf8)
        let skipped = try? CloudTranscriptionResponseParser.parse(noProbability)
        expectEqual(skipped?.hallucinationFilterSkip, .noNoSpeechProbability)
        expectEqual(skipped?.response.text, "Thank you.")

        // The Mac reads no_speech_prob only when it converts exactly to a
        // Double; the iPhone reads any JSON number.
        let wholeNumber = Data(#"{"text":"Thank you.","segments":[{"no_speech_prob":9007199254740993}]}"#.utf8)
        expectEqual((try? CloudTranscriptionResponseParser.parse(wholeNumber, options: .mac))?.response.text, "Thank you.")
        expectEqual((try? CloudTranscriptionResponseParser.parse(wholeNumber, options: .iPhone))?.response.text, "")

        // Only the iPhone reads segment times.
        let timed = Data(#"{"text":"Hello there.","segments":[{"start":0,"end":1,"text":"Hello there.","no_speech_prob":0.01}]}"#.utf8)
        expectEqual((try? CloudTranscriptionResponseParser.parse(timed, options: .mac))?.response.segments, [])
        expectEqual(
            (try? CloudTranscriptionResponseParser.parse(timed, options: .iPhone))?.response.segments,
            [.init(start: 0, end: 1, text: "Hello there.")]
        )

        // A JSON-only read rejects plain text.
        expectEqual(
            (try? CloudTranscriptionResponseParser.parseJSON(Data("Hello there.".utf8)))?.response.text,
            nil
        )
        expectEqual(
            (try? TranscriptionResponseParser.parseJSONTranscript(timed))?.text,
            "Hello there."
        )
    }

    private static func expectInvalidResponse(_ data: Data) {
        do {
            _ = try TranscriptionResponseParser.parse(data)
            preconditionFailure("Expected invalid response error")
        } catch let error as TranscriptionResponseParsingError {
            expectEqual(error, .invalidResponse)
        } catch {
            preconditionFailure("Expected TranscriptionResponseParsingError, got \(error)")
        }
    }

    private static func expectEqual<T: Equatable>(_ actual: T, _ expected: T) {
        precondition(
            actual == expected,
            "Expected \(String(describing: expected)), got \(String(describing: actual))"
        )
    }
}
