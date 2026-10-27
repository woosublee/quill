import Foundation

/// The parts of an OpenAI-compatible realtime transcription session that
/// don't depend on the socket: where to connect, the connection request, and
/// the `session.update` that configures 24 kHz PCM input with no turn
/// detection. Each app keeps its own socket handling and event loop.
public enum RealtimeTranscriptionSession {
    /// https becomes wss and http becomes ws. A path ending in
    /// `/chat/completions` or `/audio/transcriptions` is trimmed, then
    /// `/realtime` (after `/v1`) or `/v1/realtime` is added unless the path
    /// already ends in `/realtime`. `intent=transcription` is added unless an
    /// `intent` is already there.
    public static func webSocketURL(baseURL: String) -> URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed) else { return nil }

        switch components.scheme?.lowercased() {
        case "http": components.scheme = "ws"
        case "https": components.scheme = "wss"
        case "ws", "wss": break
        default: return nil
        }

        var pathComponents = components.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        if pathComponents.suffix(2) == ["chat", "completions"]
            || pathComponents.suffix(2) == ["audio", "transcriptions"] {
            pathComponents.removeLast(2)
        }
        if pathComponents.last == "realtime" {
            // Already a realtime endpoint.
        } else if pathComponents.last == "v1" {
            pathComponents.append("realtime")
        } else {
            pathComponents.append(contentsOf: ["v1", "realtime"])
        }
        components.path = "/" + pathComponents.joined(separator: "/")

        var queryItems = components.queryItems ?? []
        if !queryItems.contains(where: { $0.name == "intent" }) {
            queryItems.append(URLQueryItem(name: "intent", value: "transcription"))
        }
        components.queryItems = queryItems
        return components.url
    }

    /// The WebSocket request, with a Bearer header when there is a key. The
    /// key is trimmed first.
    public static func connectionRequest(url: URL, key: String) -> URLRequest {
        var request = URLRequest(url: url)
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// An empty model or language is left out, so the provider uses its
    /// default.
    public static func sessionUpdatePayload(model: String, language: String?) -> [String: Any] {
        var transcription: [String: Any] = [:]
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedModel.isEmpty {
            transcription["model"] = trimmedModel
        }
        if let language, !language.isEmpty {
            transcription["language"] = language
        }
        return [
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": 24_000],
                        "transcription": transcription,
                        "turn_detection": NSNull(),
                    ] as [String: Any],
                ],
            ] as [String: Any],
        ]
    }
}
