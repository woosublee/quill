import Foundation

enum LLMAPITransport {
    private static let sharedRequestTimeout: TimeInterval = 20
    private static let fallbackTimeout: TimeInterval = 60
    private static let requestSession: URLSession = {
        makeEphemeralSession(timeout: sharedRequestTimeout)
    }()

    private static func makeEphemeralSession(timeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        return URLSession(configuration: configuration)
    }

    static func timeout(for requestTimeout: TimeInterval) -> TimeInterval {
        guard requestTimeout.isFinite, requestTimeout > 0 else {
            return fallbackTimeout
        }
        return requestTimeout
    }

    static func data(
        for request: URLRequest
    ) async throws -> (Data, URLResponse) {
        let requestTimeout = timeout(for: request.timeoutInterval)
        var normalizedRequest = request
        normalizedRequest.timeoutInterval = requestTimeout
        if requestTimeout > sharedRequestTimeout {
            let session = makeEphemeralSession(timeout: requestTimeout)
            defer { session.finishTasksAndInvalidate() }
            return try await session.data(for: normalizedRequest)
        }
        return try await requestSession.data(for: normalizedRequest)
    }

    static func upload(
        for request: URLRequest,
        from bodyData: Data
    ) async throws -> (Data, URLResponse) {
        // Use a fresh session for each upload so a bad reused connection cannot
        // poison subsequent transcription uploads.
        let requestTimeout = timeout(for: request.timeoutInterval)
        var normalizedRequest = request
        normalizedRequest.timeoutInterval = requestTimeout
        let session = makeEphemeralSession(timeout: requestTimeout)
        defer { session.finishTasksAndInvalidate() }
        return try await session.upload(for: normalizedRequest, from: bodyData)
    }
}
