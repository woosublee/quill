import Foundation
import QuillAudioLevelCore

/// The recording input hints shared with the iPhone (QuillAudioLevelCore,
/// #697), built against the shared module alone. The iPhone keys a
/// recording by its own id, so the state is checked with a non-UUID one.
@main
struct RecordingInputHintStateTests {
    static func main() {
        precondition(RecordingQuietInputDetector.quietDuration == 10)
        precondition(RecordingQuietInputDetector.nearSilentLevel == 0.04)
        precondition(AudioBufferStarvationDetector.starvationTimeout == 5)

        var state = RecordingInputHintState(sessionID: "capture-1")
        state.resume(at: 0)
        precondition(state.tick(now: 1, bufferCount: 10, isCaptureSuspended: false) == nil)
        precondition(state.tick(now: 10, bufferCount: 20, isCaptureSuspended: false) == .quiet)
        precondition(state.tick(now: 15, bufferCount: 20, isCaptureSuspended: false) == .inputLost,
                     "input lost wins over quiet")
        precondition(state.tick(now: 16, bufferCount: 21, isCaptureSuspended: false) == .quiet)
        precondition(state.observeLevel(0.2) == nil, "sound ends the quiet hint for the recording")
        state.resume(at: 30)
        precondition(state.tick(now: 45, bufferCount: 0, isCaptureSuspended: false) == .inputLost)
        precondition(state.tick(now: 46, bufferCount: 0, isCaptureSuspended: true) == nil,
                     "a suspension rearms the grace window")
        let copy = state
        precondition(copy == state && copy.sessionID == "capture-1")

        precondition(RecordingInputHint.quiet.severity == .info)
        precondition(RecordingInputHint.inputLost.severity == .warning)
        precondition(RecordingInputHint.storageLow.severity == .warning)
        precondition(!RecordingInputHint.quiet.isAnnouncedToVoiceOver)
        precondition(RecordingInputHint.inputLost.isAnnouncedToVoiceOver)
        precondition(RecordingInputHint.storageLow.isAnnouncedToVoiceOver)
        precondition(RecordingInputHint.storageLow.messageKey
            == "Storage is almost full. Quill will save the recording before it runs out.")
        precondition(RecordingNoticeSeverity.allCases.map(\.symbolName) == [
            "info.circle.fill", "exclamationmark.triangle.fill", "exclamationmark.circle.fill"
        ])
        print("RecordingInputHintStateTests passed")
    }
}
