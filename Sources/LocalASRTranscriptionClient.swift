import Foundation

/// Sends one WAV chunk to the bundled `llama-server` and returns its text.
/// Never logs or keeps audio, prompts, or response text.
struct LocalASRTranscriptionClient: Sendable {
    static let maximumOutputTokens = 1_536

    let send: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    init(
        send: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
            try await LLMAPITransport.data(for: request)
        }
    ) {
        self.send = send
    }

    func transcribe(
        chunkURL: URL,
        baseURL: URL,
        format: LocalASRRequestFormat,
        languageCode: String?,
        timeoutSeconds: TimeInterval
    ) async throws -> String {
        let audioData = try Data(contentsOf: chunkURL)
        let request = try Self.makeRequest(
            baseURL: baseURL,
            audioData: audioData,
            format: format,
            languageCode: languageCode,
            timeoutSeconds: timeoutSeconds
        )
        let (data, response) = try await send(request)
        return try Self.parseResponse(data: data, response: response, format: format)
    }

    static func instruction(languageCode: String?) -> String {
        let base = "Transcribe the speech in this audio verbatim. "
            + "Output only the spoken words, with no commentary, labels, "
            + "translations, or timestamps. If there is no speech, output nothing."
        guard let languageCode,
              languageCode != "auto",
              let name = Locale(identifier: "en")
                .localizedString(forLanguageCode: languageCode) else {
            return base + " Keep the language that is spoken."
        }
        return base + " The speech is in \(name). Write the transcript in \(name)."
    }

    static func makeRequest(
        baseURL: URL,
        audioData: Data,
        format: LocalASRRequestFormat,
        languageCode: String?,
        timeoutSeconds: TimeInterval
    ) throws -> URLRequest {
        let audioPart: [String: Any] = [
            "type": "input_audio",
            "input_audio": [
                "data": audioData.base64EncodedString(),
                "format": "wav"
            ]
        ]
        let content: [[String: Any]]
        switch format {
        case .chatCompletionsInputAudio:
            content = [
                audioPart,
                ["type": "text", "text": instruction(languageCode: languageCode)]
            ]
        case .qwen3ASRChatCompletions:
            content = [audioPart]
        }
        var request = URLRequest(
            url: baseURL
                .appendingPathComponent("chat")
                .appendingPathComponent("completions")
        )
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": "local",
            "temperature": 0,
            "max_tokens": maximumOutputTokens,
            "stream": false,
            "messages": [["role": "user", "content": content]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func parseResponse(
        data: Data,
        response: URLResponse,
        format: LocalASRRequestFormat = .chatCompletionsInputAudio
    ) throws -> String {
        guard let http = response as? HTTPURLResponse else {
            throw CloudTranscriptionInvalidResponseFailure()
        }
        guard http.statusCode == 200 else {
            throw CloudTranscriptionHTTPFailure(statusCode: http.statusCode)
        }
        guard let decoded = try? JSONDecoder().decode(ChatResponse.self, from: data),
              let choice = decoded.choices.first else {
            throw CloudTranscriptionInvalidResponseFailure()
        }
        if choice.finishReason == "length" {
            throw TranscriptionChunkTruncatedFailure()
        }
        var text = choice.message.content ?? ""
        if format == .qwen3ASRChatCompletions,
           let tag = text.range(of: "<asr_text>") {
            text = String(text[tag.upperBound...])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message
            let finishReason: String?
            enum CodingKeys: String, CodingKey {
                case message
                case finishReason = "finish_reason"
            }
        }
        let choices: [Choice]
    }
}
