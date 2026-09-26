import Foundation

/// How a local speech-capable model receives audio. A new model family adds a
/// case here plus its request builder in `LocalASRTranscriptionClient`.
enum LocalASRRequestFormat: String, Codable, Hashable, Sendable {
    /// `/v1/chat/completions` with an `input_audio` content part (WAV, base64).
    case chatCompletionsInputAudio = "chat-completions-input-audio"
}
