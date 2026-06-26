import Foundation

@main
struct InstructionExecutionDetectorTests {
    static func main() {
        testAssistantPreambleIsDetectedWithOutputLanguage()
        testTokenOverlapHeuristicIsSkippedWithOutputLanguage()
        testRawAssistantPreambleDoesNotTriggerDetection()
        testTokenOverlapHeuristicStillRunsWithoutOutputLanguage()
        print("InstructionExecutionDetectorTests passed")
    }

    private static func testAssistantPreambleIsDetectedWithOutputLanguage() {
        let detected = InstructionExecutionDetector.appearsToHaveExecutedInstruction(
            rawTranscript: "write a reply to Sarah saying sorry for the delay",
            cleanedTranscript: "Sure, here's a reply you can send to Sarah: Sorry for the delay.",
            outputLanguage: "Korean"
        )

        assert(detected, "Expected assistant preamble detection to stay active with an output language")
    }

    private static func testTokenOverlapHeuristicIsSkippedWithOutputLanguage() {
        let detected = InstructionExecutionDetector.appearsToHaveExecutedInstruction(
            rawTranscript: "write a reply to Sarah saying sorry for the delay",
            cleanedTranscript: "Sarah에게 지연에 대해 사과하는 답장을 작성해 주세요.",
            outputLanguage: "Korean"
        )

        assert(!detected, "Expected token-overlap detection to be skipped with an output language")
    }

    private static func testRawAssistantPreambleDoesNotTriggerDetection() {
        let detected = InstructionExecutionDetector.appearsToHaveExecutedInstruction(
            rawTranscript: "Sure, here's what I want to say",
            cleanedTranscript: "Sure, here's what I want to say.",
            outputLanguage: "Korean"
        )

        assert(!detected, "Expected spoken assistant preamble to avoid false positives")
    }

    private static func testTokenOverlapHeuristicStillRunsWithoutOutputLanguage() {
        let detected = InstructionExecutionDetector.appearsToHaveExecutedInstruction(
            rawTranscript: "write an email to Sarah saying sorry for the delay",
            cleanedTranscript: "I apologize for the delayed response and appreciate your patience.",
            outputLanguage: ""
        )

        assert(detected, "Expected token-overlap detection to keep running without an output language")
    }
}
