import Foundation

@main
struct CriticalDictationActivityStateTests {
    static func main() {
        testBeginsWhenRecordingStarts()
        testStaysActiveWhenRecordingStopsButTranscriptionContinues()
        testEndsWhenLastTranscriptionJobFinishes()
        print("CriticalDictationActivityStateTests passed")
    }

    private static func testBeginsWhenRecordingStarts() {
        var state = CriticalDictationActivityState()

        let transition = state.update(isRecording: true, activeTranscriptionJobCount: 0)

        assert(transition == .begin)
        assert(state.isActive)
    }

    private static func testStaysActiveWhenRecordingStopsButTranscriptionContinues() {
        var state = CriticalDictationActivityState()
        _ = state.update(isRecording: true, activeTranscriptionJobCount: 0)

        let transition = state.update(isRecording: false, activeTranscriptionJobCount: 1)

        assert(transition == .none)
        assert(state.isActive)
    }

    private static func testEndsWhenLastTranscriptionJobFinishes() {
        var state = CriticalDictationActivityState()
        _ = state.update(isRecording: false, activeTranscriptionJobCount: 1)

        let transition = state.update(isRecording: false, activeTranscriptionJobCount: 0)

        assert(transition == .end)
        assert(!state.isActive)
    }
}
