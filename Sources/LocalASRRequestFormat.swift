import Foundation

/// How a local speech-capable model receives audio. A new model family adds a
/// case here plus its request builder in `LocalASRTranscriptionClient`.
enum LocalASRRequestFormat: String, Codable, Hashable, Sendable {
    /// `/v1/chat/completions` with an `input_audio` content part (WAV, base64).
    case chatCompletionsInputAudio = "chat-completions-input-audio"
    /// Qwen3-ASR: audio only (it ignores text instructions), and the reply
    /// starts with a `language <Name><asr_text>` tag before the transcript.
    case qwen3ASRChatCompletions = "qwen3-asr-chat-completions"
}
