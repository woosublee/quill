import Foundation

enum LLMAPITransport {
    private static let requestSession: URLSession = {
        makeEphemeralSession()
    }()

    private static func makeEphemeralSession(resourceTimeout: TimeInterval = 30) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = max(30, resourceTimeout)
        return URLSession(configuration: configuration)
    }

    static func data(
        for request: URLRequest
    ) async throws -> (Data, URLResponse) {
        if request.timeoutInterval > requestSession.configuration.timeoutIntervalForResource {
            let session = makeEphemeralSession(resourceTimeout: request.timeoutInterval)
            defer { session.finishTasksAndInvalidate() }
            return try await session.data(for: request)
        }
        return try await requestSession.data(for: request)
    }

    static func upload(
        for request: URLRequest,
        from bodyData: Data
    ) async throws -> (Data, URLResponse) {
        // Use a fresh session for each upload so a bad reused connection cannot
        // poison subsequent transcription uploads.
        let session = makeEphemeralSession(resourceTimeout: request.timeoutInterval)
        defer { session.finishTasksAndInvalidate() }
        return try await session.upload(for: request, from: bodyData)
    }
}
