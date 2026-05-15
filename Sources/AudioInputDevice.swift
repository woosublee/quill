enum AudioInputDevice {
    static let systemAudioID = "__system_audio__"
    static let defaultMicrophoneID = "default"

    static func isSystemAudio(_ id: String) -> Bool {
        id == systemAudioID
    }
}
