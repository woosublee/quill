struct CriticalDictationActivityState {
    enum Transition {
        case none
        case begin
        case end
    }

    private(set) var isActive = false

    mutating func update(isRecording: Bool, activeTranscriptionJobCount: Int) -> Transition {
        let shouldBeActive = isRecording || activeTranscriptionJobCount > 0
        switch (isActive, shouldBeActive) {
        case (false, true):
            isActive = true
            return .begin
        case (true, false):
            isActive = false
            return .end
        default:
            return .none
        }
    }
}
