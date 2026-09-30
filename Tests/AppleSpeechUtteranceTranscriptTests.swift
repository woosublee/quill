import Foundation

#if !QUILL_GROUPED_TEST_RUNNER
@main
#endif
struct AppleSpeechUtteranceTranscriptTests {
    static func main() throws {
        try testPauseResetKeepsEarlierUtterance()
        try testUtteranceEndCommitsBeforeNextUtterance()
        try testRevisionsInsideUtteranceReplaceText()
        try testRepeatedCommittedUtteranceIsNotDuplicated()
        try testFinalResultAfterCommitDoesNotDuplicate()
        try testLiveTranscriberUsesUtteranceTranscript()
        print("AppleSpeechUtteranceTranscriptTests passed")
    }

    // #449: after a pause the recognizer restarts with only the new words and
    // no final result; the earlier words must stay.
    private static func testPauseResetKeepsEarlierUtterance() throws {
        var transcript = AppleSpeechUtteranceTranscript()
        transcript.apply("Alpha", utteranceEnded: false)
        transcript.apply("Alpha bravo", utteranceEnded: false)
        transcript.apply("Alpha bravo charlie", utteranceEnded: false)
        transcript.apply("Delta", utteranceEnded: false)
        try expect(transcript.text == "Alpha bravo charlie Delta", "pause reset keeps earlier text")
        transcript.apply("Delta echo", utteranceEnded: true)
        try expect(transcript.text == "Alpha bravo charlie Delta echo", "final keeps every utterance")
    }

    private static func testUtteranceEndCommitsBeforeNextUtterance() throws {
        var transcript = AppleSpeechUtteranceTranscript()
        transcript.apply("Alpha bravo", utteranceEnded: false)
        transcript.apply("Alpha bravo.", utteranceEnded: true)
        transcript.apply("Charlie", utteranceEnded: false)
        try expect(transcript.text == "Alpha bravo. Charlie", "ended utterance is kept")
        transcript.apply("Charlie delta.", utteranceEnded: true)
        try expect(transcript.text == "Alpha bravo. Charlie delta.", "both utterances are kept")
    }

    private static func testRevisionsInsideUtteranceReplaceText() throws {
        var transcript = AppleSpeechUtteranceTranscript()
        transcript.apply("Alpha bravo", utteranceEnded: false)
        transcript.apply("Alpha brave", utteranceEnded: false)
        transcript.apply("Alpha", utteranceEnded: false)
        transcript.apply("Alpha bravo charlie", utteranceEnded: false)
        try expect(transcript.text == "Alpha bravo charlie", "revisions do not duplicate words")
        transcript.apply("Al", utteranceEnded: false)
        try expect(transcript.text == "Al", "a shortened revision with the same start stays one utterance")
    }

    // Recognizers that keep earlier words in later results must not duplicate them.
    private static func testRepeatedCommittedUtteranceIsNotDuplicated() throws {
        var transcript = AppleSpeechUtteranceTranscript()
        transcript.apply("Alpha bravo.", utteranceEnded: true)
        transcript.apply("Alpha bravo. Charlie", utteranceEnded: false)
        try expect(transcript.text == "Alpha bravo. Charlie", "repeated prefix is removed")
    }

    private static func testFinalResultAfterCommitDoesNotDuplicate() throws {
        var transcript = AppleSpeechUtteranceTranscript()
        transcript.apply("Alpha bravo.", utteranceEnded: true)
        transcript.apply("Alpha bravo.", utteranceEnded: true)
        try expect(transcript.text == "Alpha bravo.", "same utterance is committed once")
    }

    private static func testLiveTranscriberUsesUtteranceTranscript() throws {
        let source = try String(contentsOfFile: "Sources/AppleSpeechLiveTranscriber.swift", encoding: .utf8)
        try expect(source.contains("state.utterances.apply("), "results feed the utterance transcript")
        try expect(source.contains("state.latestTranscript = state.utterances.text"),
                   "partial, timeout, and final text include every utterance")
        try expect(!source.contains("state.latestTranscript = text\n"), "a result no longer replaces the transcript")
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw TestFailure(message) }
    }

    private struct TestFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
