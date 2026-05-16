enum AudioInputDevice {
    static let systemAudioID = "__system_audio__"
    static let meetingAudioID = "__meeting_audio__"
    static let defaultMicrophoneID = "default"

    static func isSystemAudio(_ id: String) -> Bool {
        id == systemAudioID
    }

    static func isMeetingAudio(_ id: String) -> Bool {
        id == meetingAudioID
    }

    static func isSpecialInput(_ id: String) -> Bool {
        isSystemAudio(id) || isMeetingAudio(id)
    }

    static func isMicrophoneOnly(_ id: String) -> Bool {
        !isSpecialInput(id)
    }
}
