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
        testNonFiniteNumbersAreReadOutsideStrings()
        testSharedParserOptionsAndSkips()
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

    // One behavior for both apps (#651). A bare Infinity or NaN in a number
    // position reads as null; the same words inside strings are kept; invalid
    // UTF-8 is still rejected.
    private static func testNonFiniteNumbersAreReadOutsideStrings() {
        let nonFinite = Data(#"{"text":"The result was: NaN, again","segments":[{"start":0,"end":1.5,"text":"Infinity, NaN]","compression_ratio":Infinity,"avg_logprob":-Infinity,"temperature":NaN,"no_speech_prob":0.01}]}"#.utf8)
        for options in [CloudTranscriptionResponseParser.Options.mac, .iPhone] {
            let parsed = try? CloudTranscriptionResponseParser.parse(nonFinite, options: options)
            expectEqual(parsed?.response.text, "The result was: NaN, again")
        }
        expectEqual(
            (try? CloudTranscriptionResponseParser.parse(nonFinite, options: .iPhone))?.response.segments,
            [.init(start: 0, end: 1.5, text: "Infinity, NaN]")]
        )
        expectEqual((try? TranscriptionResponseParser.parse(nonFinite))?.text, "The result was: NaN, again")
        expectEqual((try? TranscriptionResponseParser.parseJSONTranscript(nonFinite))?.text, "The result was: NaN, again")

        let escapedQuote = Data(#"{"text":"She said \"NaN\", Infinity","language":"en","extra":NaN}"#.utf8)
        expectEqual((try? TranscriptionResponseParser.parse(escapedQuote))?.text, #"She said "NaN", Infinity"#)

        // Only whole words are replaced, so a longer bare word stays invalid.
        expectInvalidResponse(Data(#"{"text":"NaN","value":NaNa}"#.utf8))

        var invalidUTF8 = Data(#"{"text":"We ship"#.utf8)
        invalidUTF8.append(0xFF)
        invalidUTF8.append(contentsOf: Array(#"","ratio":Infinity}"#.utf8))
        expectInvalidResponse(invalidUTF8)

        expectInvalidResponse(Data(#"{"text":"We ship","ratio":Infinity"#.utf8))
    }

    private static func testSharedParserOptionsAndSkips() {
        // A plain-text reply that is only punctuation and byte order marks
        // has no content.
        expectInvalidResponse(Data(".\u{FEFF}".utf8))
        expectEqual((try? TranscriptionResponseParser.parse(Data("Hi\u{FEFF}".utf8)))?.text, "Hi\u{FEFF}")

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

        // Any JSON number counts as a no-speech probability.
        let wholeNumber = Data(#"{"text":"Thank you.","segments":[{"no_speech_prob":9007199254740993}]}"#.utf8)
        expectEqual((try? TranscriptionResponseParser.parse(wholeNumber))?.text, "")

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
        expectEqual((try? TranscriptionResponseParser.parseJSONTranscript(timed))?.text, "Hello there.")
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
