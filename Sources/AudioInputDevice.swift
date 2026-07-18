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

    static func isSingleSource(_ id: String) -> Bool {
        !isSystemDefaultAndSystemAudio(id)
    }

    static func isMicrophoneOnly(_ id: String) -> Bool {
        !isSpecialInput(id)
    }

    /// Treats an empty id as the system default microphone so the two spellings
    /// compare equal.
    static func normalized(_ id: String) -> String {
        id.isEmpty ? defaultMicrophoneID : id
    }

    static func isSameInput(_ lhs: String, _ rhs: String) -> Bool {
        normalized(lhs) == normalized(rhs)
    }
}
