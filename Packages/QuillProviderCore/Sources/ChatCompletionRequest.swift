import Foundation

/// One OpenAI-compatible `chat/completions` request: a system and a user
/// message at temperature 0. Each app decides when to send the key, which
/// completion ceiling and reasoning settings to use, and what to do with the
/// reply; this only builds the request.
public struct ChatCompletionRequest: Sendable {
    public var model: String
    public var system: String
    public var user: String
    /// Sent as `max_completion_tokens`; nil sends no ceiling.
    public var completionCeiling: Int?
    public var reasoningEffort: String?
    public var includeReasoning: Bool?
    /// Local AI: llama-server reads the older `max_tokens`, so the ceiling
    /// is sent under that name too. Has no effect without a ceiling.
    public var sendsLegacyCompletionCeiling: Bool
    /// Local AI: a JSON schema spliced in as text, so it keeps its key
    /// order, under `response_format`. It must be a JSON object.
    public var responseFormatJSON: String?

    public init(
        model: String,
        system: String,
        user: String,
        completionCeiling: Int?,
        reasoningEffort: String? = nil,
        includeReasoning: Bool? = nil,
        sendsLegacyCompletionCeiling: Bool = false,
        responseFormatJSON: String? = nil
    ) {
        self.model = model
        self.system = system
        self.user = user
        self.completionCeiling = completionCeiling
        self.reasoningEffort = reasoningEffort
        self.includeReasoning = includeReasoning
        self.sendsLegacyCompletionCeiling = sendsLegacyCompletionCeiling
        self.responseFormatJSON = responseFormatJSON
    }

    /// A POST to `<baseURL>/chat/completions`. `authorizationToken` is sent
    /// as a bearer token when it isn't nil.
    public func urlRequest(
        baseURL: URL,
        authorizationToken: String?,
        timeout: TimeInterval
    ) throws -> URLRequest {
        var request = URLRequest(
            url: baseURL
                .appendingPathComponent("chat")
                .appendingPathComponent("completions")
        )
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let authorizationToken {
            request.setValue("Bearer \(authorizationToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try body()
        return request
    }

    private func body() throws -> Data {
        var payload: [String: Any] = [
            "model": model,
            "temperature": 0.0,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ]
        ]
        if let completionCeiling {
            payload["max_completion_tokens"] = completionCeiling
            if sendsLegacyCompletionCeiling {
                payload["max_tokens"] = completionCeiling
            }
        }
        if let reasoningEffort {
            payload["reasoning_effort"] = reasoningEffort
        }
        if let includeReasoning {
            payload["include_reasoning"] = includeReasoning
        }
        var body = try JSONSerialization.data(withJSONObject: payload)
        if let responseFormatJSON {
            guard (try? JSONSerialization.jsonObject(with: Data(responseFormatJSON.utf8)))
                is [String: Any] else {
                throw ChatCompletionRequestError.invalidResponseFormat
            }
            body.removeLast()
            body.append(Data(#","response_format":"#.utf8))
            body.append(Data(responseFormatJSON.utf8))
            body.append(Data("}".utf8))
        }
        return body
    }
}

public enum ChatCompletionRequestError: Error, Equatable, Sendable {
    /// `responseFormatJSON` isn't a JSON object.
    case invalidResponseFormat
}
