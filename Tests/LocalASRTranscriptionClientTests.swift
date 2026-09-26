import Foundation

@main
struct LocalASRTranscriptionClientTests {
    static func main() async {
        do {
            try requestCarriesAudioAndInstruction()
            try qwen3ASRRequestSendsAudioOnly()
            try qwen3ASRResponseDropsLanguageTag()
            try gemmaResponseKeepsTagLikeText()
            try instructionNamesExplicitLanguage()
            try parsesTranscriptText()
            try treatsEmptyContentAsSilence()
            try lengthFinishReasonIsTruncation()
            try nonOKStatusIsHTTPFailure()
            try malformedBodyIsInvalidResponse()
            try await transcribeSendsFileBytesThroughInjectedTransport()
            print("LocalASRTranscriptionClientTests passed")
        } catch {
            fputs("LocalASRTranscriptionClientTests failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static let baseURL = URL(string: "http://127.0.0.1:50123/v1")!

    private static func requestCarriesAudioAndInstruction() throws {
        let audio = Data([0x52, 0x49, 0x46, 0x46])
        let request = try LocalASRTranscriptionClient.makeRequest(
            baseURL: baseURL,
            audioData: audio,
            format: .chatCompletionsInputAudio,
            languageCode: nil,
            timeoutSeconds: 120
        )
        try expectEqual(request.url?.absoluteString, "http://127.0.0.1:50123/v1/chat/completions", "endpoint")
        try expectEqual(request.httpMethod, "POST", "method")
        try expectEqual(request.timeoutInterval, 120, "timeout")
        try expectEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json", "content type")
        try expectEqual(request.value(forHTTPHeaderField: "Authorization"), nil, "no credentials")

        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        try expectEqual(body?["temperature"] as? Double, 0, "deterministic")
        try expectEqual(body?["max_tokens"] as? Int, 1_536, "token budget")
        try expectEqual(body?["stream"] as? Bool, false, "no streaming")
        let messages = body?["messages"] as? [[String: Any]]
        let content = messages?.first?["content"] as? [[String: Any]]
        let audioPart = content?.first { $0["type"] as? String == "input_audio" }
        let inputAudio = audioPart?["input_audio"] as? [String: Any]
        try expectEqual(inputAudio?["format"] as? String, "wav", "wav format")
        try expectEqual(inputAudio?["data"] as? String, audio.base64EncodedString(), "base64 audio")
        let textPart = content?.first { $0["type"] as? String == "text" }
        try expectEqual(
            textPart?["text"] as? String,
            LocalASRTranscriptionClient.instruction(languageCode: nil),
            "instruction text"
        )
    }

    private static func qwen3ASRRequestSendsAudioOnly() throws {
        let request = try LocalASRTranscriptionClient.makeRequest(
            baseURL: baseURL,
            audioData: Data([1, 2]),
            format: .qwen3ASRChatCompletions,
            languageCode: "ko",
            timeoutSeconds: 120
        )
        try expectEqual(request.url?.absoluteString, "http://127.0.0.1:50123/v1/chat/completions", "endpoint")
        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        try expectEqual(body?["max_tokens"] as? Int, 1_536, "token budget")
        let messages = body?["messages"] as? [[String: Any]]
        let content = messages?.first?["content"] as? [[String: Any]]
        // Qwen3-ASR ignores text instructions, so only the audio is sent.
        try expectEqual(content?.count, 1, "audio part only")
        try expectEqual(content?.first?["type"] as? String, "input_audio", "audio part")
    }

    private static func qwen3ASRResponseDropsLanguageTag() throws {
        let tagged = try LocalASRTranscriptionClient.parseResponse(
            data: responseBody(content: "language Korean<asr_text>안녕하세요.", finishReason: "stop"),
            response: http(200),
            format: .qwen3ASRChatCompletions
        )
        try expectEqual(tagged, "안녕하세요.", "language tag removed")
        let silent = try LocalASRTranscriptionClient.parseResponse(
            data: responseBody(content: "language None<asr_text>", finishReason: "stop"),
            response: http(200),
            format: .qwen3ASRChatCompletions
        )
        try expectEqual(silent, "", "no speech is empty")
        let untagged = try LocalASRTranscriptionClient.parseResponse(
            data: responseBody(content: " plain text ", finishReason: "stop"),
            response: http(200),
            format: .qwen3ASRChatCompletions
        )
        try expectEqual(untagged, "plain text", "untagged text kept")
    }

    private static func gemmaResponseKeepsTagLikeText() throws {
        let text = try LocalASRTranscriptionClient.parseResponse(
            data: responseBody(content: "language Korean<asr_text>x", finishReason: "stop"),
            response: http(200),
            format: .chatCompletionsInputAudio
        )
        try expectEqual(text, "language Korean<asr_text>x", "other formats unchanged")
    }

    private static func instructionNamesExplicitLanguage() throws {
        let auto = LocalASRTranscriptionClient.instruction(languageCode: nil)
        try expectEqual(auto.contains("Keep the language that is spoken."), true, "auto keeps language")
        let korean = LocalASRTranscriptionClient.instruction(languageCode: "ko")
        try expectEqual(korean.contains("The speech is in Korean"), true, "names Korean")
        let unknown = LocalASRTranscriptionClient.instruction(languageCode: "auto")
        try expectEqual(unknown, auto, "auto code treated as automatic")
    }

    private static func parsesTranscriptText() throws {
        let text = try LocalASRTranscriptionClient.parseResponse(
            data: responseBody(content: "  Hello there.  ", finishReason: "stop"),
            response: http(200)
        )
        try expectEqual(text, "Hello there.", "trimmed text")
    }

    private static func treatsEmptyContentAsSilence() throws {
        let text = try LocalASRTranscriptionClient.parseResponse(
            data: responseBody(content: nil, finishReason: "stop"),
            response: http(200)
        )
        try expectEqual(text, "", "null content is silence")
    }

    private static func lengthFinishReasonIsTruncation() throws {
        do {
            _ = try LocalASRTranscriptionClient.parseResponse(
                data: responseBody(content: "partial", finishReason: "length"),
                response: http(200)
            )
            throw TestFailure("expected truncation")
        } catch is TranscriptionChunkTruncatedFailure {
        }
    }

    private static func nonOKStatusIsHTTPFailure() throws {
        do {
            _ = try LocalASRTranscriptionClient.parseResponse(data: Data("{}".utf8), response: http(503))
            throw TestFailure("expected HTTP failure")
        } catch let failure as CloudTranscriptionHTTPFailure {
            try expectEqual(failure.statusCode, 503, "status kept")
            try expectEqual(failure.sanitizedMessage, nil, "no body text kept")
        }
    }

    private static func malformedBodyIsInvalidResponse() throws {
        do {
            _ = try LocalASRTranscriptionClient.parseResponse(data: Data("not json".utf8), response: http(200))
            throw TestFailure("expected invalid response")
        } catch is CloudTranscriptionInvalidResponseFailure {
        }
    }

    private static func transcribeSendsFileBytesThroughInjectedTransport() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        let bytes = Data([1, 2, 3, 4])
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let captured = RequestBox()
        let client = LocalASRTranscriptionClient { request in
            captured.set(request)
            return (responseBody(content: "ok", finishReason: "stop"), http(200))
        }
        let text = try await client.transcribe(
            chunkURL: url,
            baseURL: baseURL,
            format: .chatCompletionsInputAudio,
            languageCode: "en",
            timeoutSeconds: 120
        )
        try expectEqual(text, "ok", "result")
        let body = String(decoding: captured.get()?.httpBody ?? Data(), as: UTF8.self)
        try expectEqual(body.contains(bytes.base64EncodedString()), true, "file bytes sent")
    }

    private static func responseBody(content: String?, finishReason: String) -> Data {
        let message: [String: Any] = content.map { ["role": "assistant", "content": $0] }
            ?? ["role": "assistant", "content": NSNull()]
        let object: [String: Any] = [
            "choices": [["index": 0, "message": message, "finish_reason": finishReason]]
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private static func http(_ status: Int) -> URLResponse {
        HTTPURLResponse(url: baseURL, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    private static func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) throws {
        guard actual == expected else {
            throw TestFailure("\(label): expected \(expected), got \(actual)")
        }
    }
}

private final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var request: URLRequest?
    func set(_ value: URLRequest) { lock.lock(); request = value; lock.unlock() }
    func get() -> URLRequest? { lock.lock(); defer { lock.unlock() }; return request }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
