enum AudioInputDevice {
    static let systemAudioID = "__system_audio__"
    static let systemDefaultAndSystemAudioID = "__system_default_and_system_audio__"
    static let defaultMicrophoneID = "default"

    static func isSystemAudio(_ id: String) -> Bool {
        id == systemAudioID
    }

    static func isSystemDefaultAndSystemAudio(_ id: String) -> Bool {
        id == systemDefaultAndSystemAudioID
    }

    static func isSpecialInput(_ id: String) -> Bool {
        isSystemAudio(id) || isSystemDefaultAndSystemAudio(id)
    }

    static func isMicrophoneOnly(_ id: String) -> Bool {
        !isSpecialInput(id)
    }
}
