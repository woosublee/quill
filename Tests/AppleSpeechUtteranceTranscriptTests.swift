import Foundation

#if !QUILL_GROUPED_TEST_RUNNER
@main
#endif
struct AppleSpeechUtteranceTranscriptTests {
    static func main() throws {
        try testUtteranceEndCommitsBeforeNextUtterance()
        try testRestartWithSameFirstWordKeepsEarlierUtterance()
        try testRestartWithoutSpacesKeepsEarlierUtterance()
        try testRevisionsInsideUtteranceDoNotDuplicate()
        try testRepeatedPhraseIsKeptTwice()
        try testNewUtteranceIsNotCutAtCommittedPrefix()
        try testFinalResultRevisingLastUtteranceDoesNotDuplicate()
        try testEmptyResultsKeepText()
        try testLiveTranscriberUsesUtteranceTranscript()
        print("AppleSpeechUtteranceTranscriptTests passed")
    }

    // #449: the recognizer marks each pause and then starts over with only the
    // new words; the earlier words must stay.
    private static func testUtteranceEndCommitsBeforeNextUtterance() throws {
        var transcript = AppleSpeechUtteranceTranscript()
        transcript.apply("Alpha bravo", utteranceEnded: false)
        transcript.apply("Alpha bravo.", utteranceEnded: true)
        transcript.apply("Charlie", utteranceEnded: false)
        try expect(transcript.text == "Alpha bravo. Charlie", "ended utterance is kept")
        transcript.apply("Charlie delta.", utteranceEnded: true)
        try expect(transcript.text == "Alpha bravo. Charlie delta.", "both utterances are kept")
    }

    // Without an end marker, a restart that begins with the same word is still detected.
    private static func testRestartWithSameFirstWordKeepsEarlierUtterance() throws {
        var transcript = AppleSpeechUtteranceTranscript()
        transcript.apply("I think we should go", utteranceEnded: false)
        transcript.apply("I", utteranceEnded: false)
        transcript.apply("I agree", utteranceEnded: false)
        try expect(transcript.text == "I think we should go I agree", "restart keeps earlier text")
    }

    private static func testRestartWithoutSpacesKeepsEarlierUtterance() throws {
        var transcript = AppleSpeechUtteranceTranscript()
        transcript.apply("合成テストの文章です", utteranceEnded: false)
        transcript.apply("次", utteranceEnded: false)
        try expect(transcript.text == "合成テストの文章です 次", "restart is detected without spaces")
    }

    private static func testRevisionsInsideUtteranceDoNotDuplicate() throws {
        var transcript = AppleSpeechUtteranceTranscript()
        transcript.apply("Alpha bravo", utteranceEnded: false)
        transcript.apply("Alpha brave", utteranceEnded: false)
        transcript.apply("Alpha bravo charlie", utteranceEnded: false)
        try expect(transcript.text == "Alpha bravo charlie", "growing revisions replace text")

        transcript = AppleSpeechUtteranceTranscript()
        transcript.apply("Um so we", utteranceEnded: false)
        transcript.apply("So we", utteranceEnded: false)
        try expect(transcript.text == "So we", "dropping a filler word is a revision")

        transcript = AppleSpeechUtteranceTranscript()
        transcript.apply("Hey there", utteranceEnded: false)
        transcript.apply("Hi there", utteranceEnded: false)
        try expect(transcript.text == "Hi there", "changing the first word is a revision")
    }

    private static func testRepeatedPhraseIsKeptTwice() throws {
        var transcript = AppleSpeechUtteranceTranscript()
        transcript.apply("Thank you.", utteranceEnded: true)
        transcript.apply("Thank", utteranceEnded: false)
        transcript.apply("Thank you.", utteranceEnded: true)
        try expect(transcript.text == "Thank you. Thank you.", "a repeated phrase is not dropped")
    }

    private static func testNewUtteranceIsNotCutAtCommittedPrefix() throws {
        var transcript = AppleSpeechUtteranceTranscript()
        transcript.apply("So", utteranceEnded: true)
        transcript.apply("Sorry about that", utteranceEnded: false)
        try expect(transcript.text == "So Sorry about that", "new utterance keeps its first word")
    }

    private static func testFinalResultRevisingLastUtteranceDoesNotDuplicate() throws {
        var transcript = AppleSpeechUtteranceTranscript()
        transcript.apply("Alpha.", utteranceEnded: true)
        transcript.apply("Bravo charlie", utteranceEnded: false)
        transcript.apply("Bravo charlie", utteranceEnded: true)
        transcript.apply("Bravo, charlie.", utteranceEnded: true)
        try expect(transcript.text == "Alpha. Bravo, charlie.", "final result revises the last utterance")
    }

    private static func testEmptyResultsKeepText() throws {
        var transcript = AppleSpeechUtteranceTranscript()
        transcript.apply("Alpha bravo", utteranceEnded: false)
        transcript.apply("", utteranceEnded: false)
        try expect(transcript.text == "Alpha bravo", "empty partial keeps text")
        transcript.apply("", utteranceEnded: true)
        transcript.apply("Charlie", utteranceEnded: false)
        try expect(transcript.text == "Alpha bravo Charlie", "empty end marker commits current text")
    }

    private static func testLiveTranscriberUsesUtteranceTranscript() throws {
        let source = try String(contentsOfFile: "Sources/AppleSpeechLiveTranscriber.swift", encoding: .utf8)
        try expect(source.contains("state.utterances.apply("), "results feed the utterance transcript")
        try expect(source.contains("state.latestTranscript = state.utterances.text"),
                   "partial, timeout, and final text include every utterance")
        try expect(source.contains("let utteranceEnded = result.speechRecognitionMetadata != nil"),
                   "speech metadata marks the end of an utterance")
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw TestFailure(message) }
    }

    private struct TestFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
