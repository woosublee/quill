import Foundation

/// Builds one OpenAI-compatible cloud transcription request: `POST
/// {base}/audio/transcriptions` with a Bearer key and a multipart body
/// (`model`, `response_format`, optional `language`, then `file`). Each app
/// sends it with its own transport and keeps its own logging.
public enum CloudTranscriptionUpload {
    private static let modelsSupportingVerboseJSON: Set<String> = [
        "whisper-1",
        "whisper-large-v3",
        "whisper-large-v3-turbo",
    ]

    /// `verbose_json` for the Whisper models that support it, which adds
    /// segments; `json` otherwise.
    public static func responseFormat(forModel model: String) -> String {
        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return modelsSupportingVerboseJSON.contains(normalizedModel) ? "verbose_json" : "json"
    }

    public static func contentType(forFileName fileName: String) -> String {
        let lowercased = fileName.lowercased()
        if lowercased.hasSuffix(".wav") { return "audio/wav" }
        if lowercased.hasSuffix(".mp3") { return "audio/mpeg" }
        return "audio/mp4"
    }

    public static func request(
        baseURL: URL,
        key: String,
        timeout: TimeInterval,
        boundary: String
    ) -> URLRequest {
        var request = URLRequest(
            url: baseURL.appendingPathComponent("audio").appendingPathComponent("transcriptions")
        )
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        return request
    }

    public static func multipartBody(
        audioData: Data,
        fileName: String,
        model: String,
        responseFormat: String,
        language: String?,
        boundary: String
    ) -> Data {
        var body = Data()
        func append(_ value: String) { body.append(Data(value.utf8)) }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        append("\(model)\r\n")

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n")
        append("\(responseFormat)\r\n")

        if let language, !language.isEmpty {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"language\"\r\n\r\n")
            append("\(language)\r\n")
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n")
        append("Content-Type: \(contentType(forFileName: fileName))\r\n\r\n")
        body.append(audioData)
        append("\r\n")
        append("--\(boundary)--\r\n")
        return body
    }

    /// A failed reply as a retryable failure. Only the provider's error code
    /// and type are kept, trimmed to 256 characters; its message is dropped
    /// because it can echo user text.
    public static func httpFailure(data: Data, response: HTTPURLResponse) -> CloudTranscriptionHTTPFailure {
        let retryAfterSeconds = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
        let errorObject = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let providerError = errorObject?["error"] as? [String: Any]
        return CloudTranscriptionHTTPFailure(
            statusCode: response.statusCode,
            retryAfterSeconds: retryAfterSeconds,
            providerCode: safeProviderErrorField(providerError?["code"]),
            providerType: safeProviderErrorField(providerError?["type"])
        )
    }

    private static func safeProviderErrorField(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let sanitized = value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(256)
        return sanitized.isEmpty ? nil : String(sanitized)
    }
}
