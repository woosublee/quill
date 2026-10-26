import Foundation

/// Sends cloud AI requests. Short requests share one cache-free session;
/// longer requests and uploads get a fresh one. A provider that rejects
/// `temperature` is retried once without it. Tests pass `protocolClasses` to
/// stub the provider. It holds only values fixed at creation, so callers can
/// share it.
public struct LLMAPITransport: @unchecked Sendable {
    public static let shared = LLMAPITransport(protocolClasses: [])

    private static let sharedRequestTimeout: TimeInterval = 20
    private static let fallbackTimeout: TimeInterval = 60

    private let protocolClasses: [AnyClass]
    private let requestSession: URLSession
    private let temperatureCache: TemperatureCapabilityCache

    public init(protocolClasses: [AnyClass], temperatureCache: TemperatureCapabilityCache = .shared) {
        self.protocolClasses = protocolClasses
        self.temperatureCache = temperatureCache
        requestSession = Self.makeEphemeralSession(timeout: Self.sharedRequestTimeout, protocolClasses: protocolClasses)
    }

    private static func makeEphemeralSession(timeout: TimeInterval, protocolClasses: [AnyClass]) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        if !protocolClasses.isEmpty {
            configuration.protocolClasses = protocolClasses
        }
        return URLSession(configuration: configuration)
    }

    public static func timeout(for requestTimeout: TimeInterval) -> TimeInterval {
        guard requestTimeout.isFinite, requestTimeout > 0 else {
            return fallbackTimeout
        }
        return requestTimeout
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let requestTimeout = Self.timeout(for: request.timeoutInterval)
        var normalizedRequest = request
        normalizedRequest.timeoutInterval = requestTimeout
        if requestTimeout > Self.sharedRequestTimeout {
            let session = Self.makeEphemeralSession(timeout: requestTimeout, protocolClasses: protocolClasses)
            defer { session.finishTasksAndInvalidate() }
            return try await data(for: normalizedRequest, using: session)
        }
        return try await data(for: normalizedRequest, using: requestSession)
    }

    /// Sends a chat request, and once more without `temperature` when the
    /// provider rejects that parameter as unsupported. The outcome is
    /// remembered so later requests to the same endpoint and model skip it.
    private func data(for request: URLRequest, using session: URLSession) async throws -> (Data, URLResponse) {
        let cache = temperatureCache
        let observation = cache.beginObservation(for: request)
        let capability = observation.capability
        let outgoing = capability == .unsupported ? Self.requestWithoutTemperature(request) ?? request : request
        let result = try await session.data(for: outgoing)
        if let response = result.1 as? HTTPURLResponse, response.statusCode == 200,
           Self.isValidCompletionResponse(result.0), Self.payloadHasTemperature(outgoing) {
            cache.record(.supported, for: outgoing, observation: observation)
        }
        guard capability != .unsupported,
              let response = result.1 as? HTTPURLResponse,
              response.statusCode == 400,
              let retry = Self.requestWithoutUnsupportedTemperature(outgoing, errorData: result.0) else {
            return result
        }
        cache.record(.unsupported, for: outgoing, observation: observation)
        return try await session.data(for: retry)
    }

    private static func payloadHasTemperature(_ request: URLRequest) -> Bool {
        guard let body = request.httpBody,
              let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return false }
        return payload["temperature"] != nil
    }

    private static func isValidCompletionResponse(_ data: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]], !choices.isEmpty,
              let message = choices[0]["message"] as? [String: Any] else { return false }
        return message["content"] != nil || message["reasoning"] != nil
    }

    private static func requestWithoutTemperature(_ request: URLRequest) -> URLRequest? {
        guard let body = request.httpBody,
              var payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              payload.removeValue(forKey: "temperature") != nil,
              let retryBody = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        var retry = request
        retry.httpBody = retryBody
        return retry
    }

    /// Only an explicit "temperature is unsupported" rejection counts. Range
    /// errors and other parameters keep the original failure.
    private static func requestWithoutUnsupportedTemperature(
        _ request: URLRequest,
        errorData: Data
    ) -> URLRequest? {
        guard request.httpBody != nil,
              let error = try? JSONSerialization.jsonObject(with: errorData) as? [String: Any],
              let details = error["error"] as? [String: Any] else {
            return nil
        }
        let code = (details["code"] as? String ?? "").lowercased()
        let param = (details["param"] as? String ?? "").lowercased()
        let message = (details["message"] as? String ?? "").lowercased()
        let unsupportedCode = code == "unsupported_parameter" || code == "unsupported_value"
        let unsupportedMessage = message.contains("unsupported") ||
            message.contains("not supported") || message.contains("does not support")
        guard unsupportedCode && param == "temperature" && unsupportedMessage else {
            return nil
        }
        return requestWithoutTemperature(request)
    }

    public func upload(for request: URLRequest, from bodyData: Data) async throws -> (Data, URLResponse) {
        // Use a fresh session for each upload so a bad reused connection cannot
        // poison subsequent transcription uploads.
        let requestTimeout = Self.timeout(for: request.timeoutInterval)
        var normalizedRequest = request
        normalizedRequest.timeoutInterval = requestTimeout
        let session = Self.makeEphemeralSession(timeout: requestTimeout, protocolClasses: protocolClasses)
        defer { session.finishTasksAndInvalidate() }
        return try await session.upload(for: normalizedRequest, from: bodyData)
    }
}
