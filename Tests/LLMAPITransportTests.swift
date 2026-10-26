import Foundation
import QuillProviderCore

@main
struct LLMAPITransportTests {
    static func main() async throws {
        try await testUnsupportedTemperatureRetriesOnceWithoutIt()
        try await testShortRequestsUseTheSharedSession()
        try await testOnlyExplicitTemperatureRejectionsRetry()
        try await testRejectionIsRememberedForTheEndpoint()
        try await testOtherErrorsLeaveTheCacheAlone()
        try testCacheKeysAndLifetime()
        try await testAPIKeyCheckSortsProviderReplies()
        print("LLMAPITransportTests passed")
    }

    private static let rejected = #"{"error":{"code":"unsupported_parameter","param":"temperature","message":"temperature is unsupported"}}"#
    private static let validCompletion = #"{"choices":[{"message":{"role":"assistant","content":"OK"}}]}"#

    private static func testUnsupportedTemperatureRetriesOnceWithoutIt() async throws {
        let retry = try await perform([(400, rejected), (200, validCompletion)])
        try expect(retry.count == 2, "unsupported temperature retries once")
        let original = try body(retry[0])
        let retried = try body(retry[1])
        try expect(original["temperature"] != nil, "first request keeps temperature")
        try expect(
            retried["temperature"] == nil
                && retried["model"] as? String == "fixture"
                && retried["messages"] != nil
                && retried["top_p"] as? Double == 0.7
                && retried["max_completion_tokens"] as? Int == 128,
            "retry removes only temperature"
        )
        try expect(
            retry.allSatisfy {
                $0.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-test-token"
                    && $0.value(forHTTPHeaderField: "Content-Type") == "application/json"
            },
            "retry keeps authorization and content type"
        )

        let openAIStyle = #"{"error":{"code":"unsupported_value","param":"temperature","message":"Unsupported value: 'temperature' does not support 0 with this model. Only the default (1) value is supported."}}"#
        let openAIRetry = try await perform([(400, openAIStyle), (200, validCompletion)])
        try expect(openAIRetry.count == 2, "unsupported_value retries once")

        let rejectedTwice = try await perform([(400, rejected), (400, rejected)])
        try expect(rejectedTwice.count == 2, "a second rejection stops after one retry")

        let success = try await perform([(200, validCompletion)])
        try expect(success.count == 1 && (try body(success[0]))["temperature"] != nil, "a compatible call keeps temperature")
    }

    // A request at or under 20 seconds goes through the transport's shared
    // session instead of a fresh one; it must carry the same stub provider.
    private static func testShortRequestsUseTheSharedSession() async throws {
        let retry = try await perform([(400, rejected), (200, validCompletion)], timeout: 20)
        try expect(retry.count == 2, "a short request retries once through the shared session")
        try expect(try body(retry[1])["temperature"] == nil, "the shared-session retry removes temperature")
    }

    private static func testOnlyExplicitTemperatureRejectionsRetry() async throws {
        for (reply, label) in [
            (#"{"error":{"code":"unsupported_parameter","param":"max_tokens","message":"Unsupported parameter"}}"#, "another parameter"),
            (#"{"error":{"code":"unsupported_parameter","param":null,"message":"temperature is not supported with this model"}}"#, "no parameter name"),
            (#"{"error":{"code":"unsupported_parameter","param":null,"message":"temperature is supported; top_p is unsupported"}}"#, "mixed parameters"),
            (#"{"error":{"code":"unsupported_parameter","param":"temperature","message":"value must be between 0 and 2"}}"#, "range error"),
            (#"{"error":{"code":"invalid_api_key","message":"bad key"}}"#, "unrelated 400")
        ] {
            let requests = try await perform([(400, reply)])
            try expect(requests.count == 1, "\(label) does not retry")
        }
        let withoutTemperature = try await perform([(400, rejected)], body: ["model": "fixture", "messages": []])
        try expect(withoutTemperature.count == 1, "a request without temperature does not retry")
    }

    private static func testRejectionIsRememberedForTheEndpoint() async throws {
        let cache = makeCache()
        let endpoint = UUID().uuidString
        let first = try await perform([(400, rejected), (200, validCompletion)], endpoint: endpoint, cache: cache)
        let next = try await perform([(200, validCompletion)], endpoint: endpoint, cache: cache)
        try expect(first.count == 2 && next.count == 1, "a remembered rejection needs no retry")
        try expect((try body(next[0]))["temperature"] == nil, "a remembered rejection omits temperature")

        let supported = makeCache()
        let supportedEndpoint = UUID().uuidString
        _ = try await perform([(200, validCompletion)], endpoint: supportedEndpoint, cache: supported)
        let again = try await perform([(200, validCompletion)], endpoint: supportedEndpoint, cache: supported)
        try expect(again.count == 1 && (try body(again[0]))["temperature"] != nil, "a supported endpoint keeps temperature")

        // A success observed before a newer rejection must not overwrite it.
        let stale = makeCache()
        let sharedEndpoint = UUID().uuidString
        let request = try makeRequest(endpoint: sharedEndpoint)
        let staleObservation = stale.beginObservation(for: request)
        _ = try await perform([(400, rejected), (200, validCompletion)], endpoint: sharedEndpoint, cache: stale)
        stale.record(.supported, for: request, observation: staleObservation)
        try expect(stale.capability(for: request) == .unsupported, "a stale success is ignored")
    }

    private static func testOtherErrorsLeaveTheCacheAlone() async throws {
        for (status, reply, label) in [
            (401, #"{"error":{"code":"invalid_api_key","message":"bad key"}}"#, "auth"),
            (429, #"{"error":{"code":"rate_limit_exceeded"}}"#, "rate limit"),
            (400, #"{"error":{"code":"invalid_request","message":"bad request"}}"#, "unrelated 400")
        ] {
            let cache = makeCache()
            let endpoint = UUID().uuidString
            _ = try await perform([(status, reply)], endpoint: endpoint, cache: cache)
            let next = try await perform([(200, validCompletion)], endpoint: endpoint, cache: cache)
            try expect(next.count == 1 && (try body(next[0]))["temperature"] != nil, "\(label) errors don't change the cache")
        }
    }

    private static func testCacheKeysAndLifetime() throws {
        let suite = "LLMAPITransportTests-cache-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var now = Date(timeIntervalSince1970: 1_000)
        let cache = TemperatureCapabilityCache(defaults: defaults, key: "cache", now: { now })
        func request(model: String = "model", temperature: Double = 0, token: String = "synthetic-secret", host: String = "provider.invalid") throws -> URLRequest {
            var request = URLRequest(url: URL(string: "https://\(host)/v1/chat/completions")!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": model,
                "temperature": temperature,
                "messages": [["role": "user", "content": "synthetic prompt"]]
            ])
            return request
        }

        let original = try request()
        cache.record(.unsupported, for: original)
        try expect(cache.capability(for: original) == .unsupported, "a rejection is stored")
        try expect(cache.capability(for: try request(model: "other")) == nil, "per model")
        try expect(cache.capability(for: try request(temperature: 0.2)) == nil, "per temperature")
        try expect(cache.capability(for: try request(host: "other.invalid")) == nil, "per endpoint")
        try expect(cache.capability(for: try request(token: "another-key")) == .unsupported, "the API key is not part of the entry")
        var longer = try request()
        var longerBody = try JSONSerialization.jsonObject(with: longer.httpBody!) as! [String: Any]
        longerBody["max_completion_tokens"] = 4_096
        longer.httpBody = try JSONSerialization.data(withJSONObject: longerBody)
        try expect(cache.capability(for: longer) == .unsupported, "token limits are not part of the entry")
        let stored = String(data: defaults.data(forKey: "cache")!, encoding: .utf8)!
        try expect(!stored.contains("synthetic-secret") && !stored.contains("synthetic prompt"), "no credentials or prompt are stored")
        now.addTimeInterval(7 * 24 * 60 * 60)
        try expect(cache.capability(for: original) == nil, "entries expire after 7 days")

        now = Date(timeIntervalSince1970: 3_000)
        let supported = try request(model: "supported")
        cache.record(.supported, for: supported)
        now.addTimeInterval((7 * 24 * 60 * 60) / 2 - 1)
        cache.record(.supported, for: supported)
        now.addTimeInterval((7 * 24 * 60 * 60) / 2 + 1)
        try expect(cache.capability(for: supported) == nil, "a fresh repeat isn't rewritten before half its lifetime")
    }

    // MARK: - Helpers

    private static func makeCache() -> TemperatureCapabilityCache {
        TemperatureCapabilityCache(defaults: UserDefaults(suiteName: "LLMAPITransportTests-\(UUID().uuidString)")!)
    }

    // The shared key check the Mac and the iPhone use: GET {base}/models with
    // a Bearer key and a 10 s timeout; only 200 passes.
    private static func testAPIKeyCheckSortsProviderReplies() async throws {
        let transport = LLMAPITransport(protocolClasses: [StubLLMURLProtocol.self], temperatureCache: makeCache())
        let validator = CloudAPIKeyValidator(transport: transport)
        let cases: [(Int, CloudAPIKeyValidationResult)] = [
            (200, .valid), (401, .rejected), (403, .rejected), (404, .notFound),
            (429, .rateLimited), (500, .unreachable),
        ]
        for (status, expected) in cases {
            StubLLMURLProtocol.reset([(status, "{}")])
            let result = await validator.validate(key: " synthetic-key ", baseURL: "https://provider.invalid/v1/")
            try expect(result == expected, "status \(status) gives \(expected), got \(result)")
            let request = StubLLMURLProtocol.recordedRequests().first
            try expect(request?.url?.absoluteString == "https://provider.invalid/v1/models", "key check URL")
            try expect(request?.httpMethod == "GET", "key check method")
            try expect(request?.timeoutInterval == 10, "key check timeout")
            try expect(
                request?.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-key",
                "key check trims the key into a Bearer header"
            )
        }

        StubLLMURLProtocol.reset([])
        let emptyKey = await validator.validate(key: "  ", baseURL: "https://provider.invalid/v1")
        try expect(emptyKey == .rejected, "empty key")
        let badURL = await validator.validate(key: "synthetic-key", baseURL: "ftp://provider.invalid")
        try expect(badURL == .invalidURL, "bad URL")
        try expect(StubLLMURLProtocol.recordedRequests().isEmpty, "no request for an empty key or a bad URL")
    }

    private static func makeRequest(
        endpoint: String,
        body payload: [String: Any] = ["model": "fixture", "temperature": 0, "top_p": 0.7, "max_completion_tokens": 128, "messages": []]
    ) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "https://provider.invalid/\(endpoint)/chat")!)
        request.httpMethod = "POST"
        request.setValue("Bearer synthetic-test-token", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return request
    }

    private static func perform(
        _ replies: [(Int, String)],
        body payload: [String: Any] = ["model": "fixture", "temperature": 0, "top_p": 0.7, "max_completion_tokens": 128, "messages": []],
        endpoint: String = UUID().uuidString,
        cache: TemperatureCapabilityCache = makeCache(),
        timeout: TimeInterval? = nil
    ) async throws -> [URLRequest] {
        StubLLMURLProtocol.reset(replies)
        let transport = LLMAPITransport(protocolClasses: [StubLLMURLProtocol.self], temperatureCache: cache)
        var request = try makeRequest(endpoint: endpoint, body: payload)
        if let timeout { request.timeoutInterval = timeout }
        _ = try await transport.data(for: request)
        return StubLLMURLProtocol.recordedRequests()
    }

    private static func body(_ request: URLRequest) throws -> [String: Any] {
        guard let data = bodyData(request),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMAPITransportTestFailure("request body")
        }
        return json
    }

    private static func bodyData(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try condition() else { throw LLMAPITransportTestFailure(label) }
    }
}

private struct LLMAPITransportTestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private final class StubLLMURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [(Int, String)] = []
    nonisolated(unsafe) private static var requests: [URLRequest] = []

    static func reset(_ newReplies: [(Int, String)]) {
        lock.withLock {
            replies = newReplies
            requests = []
        }
    }

    static func recordedRequests() -> [URLRequest] {
        lock.withLock { requests }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (status, body) = Self.lock.withLock { () -> (Int, String) in
            Self.requests.append(request)
            return Self.replies.removeFirst()
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
