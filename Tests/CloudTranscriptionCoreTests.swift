import Foundation

@main
struct CloudTranscriptionCoreTests {
    static func main() {
        do {
            try classifiesRetryableURLErrors()
            try classifiesHTTPFailures()
            try respectsShortRetryAfter()
            try treatsQuotaAndAuthenticationAsTerminal()
            try stopsAfterRetryBudgetIsExhausted()
            try calculatesSizeAwareAttemptTimeout()
            print("CloudTranscriptionCoreTests passed")
        } catch {
            fputs("CloudTranscriptionCoreTests failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func classifiesRetryableURLErrors() throws {
        let policy = makePolicy()
        let retryable: [URLError.Code] = [
            .timedOut,
            .networkConnectionLost,
            .notConnectedToInternet,
            .cannotConnectToHost,
            .cannotFindHost,
            .dnsLookupFailed
        ]
        for code in retryable {
            let decision = policy.decision(
                for: URLError(code),
                completedAttemptCount: 1
            )
            try expectEqual(decision.shouldRetry, true, "retry URL error \(code)")
            try expectEqual(decision.category, .transientNetwork, "URL category \(code)")
            try expectEqual(decision.delaySeconds, 1.25, "URL delay \(code)")
        }

        let certificate = policy.decision(
            for: URLError(.serverCertificateUntrusted),
            completedAttemptCount: 1
        )
        try expectEqual(certificate.shouldRetry, false, "certificate terminal")
        try expectEqual(certificate.category, .invalidRequest, "certificate category")

        let cancelled = policy.decision(
            for: CancellationError(),
            completedAttemptCount: 1
        )
        try expectEqual(cancelled.shouldRetry, false, "cancellation terminal")
        try expectEqual(cancelled.category, .cancelled, "cancellation category")
    }

    private static func classifiesHTTPFailures() throws {
        let policy = makePolicy()
        for status in [408, 500, 503] {
            let decision = policy.decision(
                for: CloudTranscriptionHTTPFailure(statusCode: status),
                completedAttemptCount: 1
            )
            try expectEqual(decision.shouldRetry, true, "HTTP \(status) retry")
            let expected: CloudTranscriptionFailureCategory = status == 408
                ? .transientNetwork
                : .providerUnavailable
            try expectEqual(decision.category, expected, "HTTP \(status) category")
        }

        let temporaryRateLimit = policy.decision(
            for: CloudTranscriptionHTTPFailure(
                statusCode: 429,
                providerCode: "rate_limit_exceeded"
            ),
            completedAttemptCount: 1
        )
        try expectEqual(temporaryRateLimit.shouldRetry, true, "temporary 429 retry")
        try expectEqual(temporaryRateLimit.category, .rateLimited, "temporary 429 category")

        let terminalCases: [(Int, CloudTranscriptionFailureCategory)] = [
            (400, .invalidRequest),
            (401, .authentication),
            (403, .authentication),
            (404, .invalidRequest),
            (413, .payloadTooLarge),
            (415, .invalidRequest),
            (422, .invalidRequest)
        ]
        for (status, category) in terminalCases {
            let decision = policy.decision(
                for: CloudTranscriptionHTTPFailure(statusCode: status),
                completedAttemptCount: 1
            )
            try expectEqual(decision.shouldRetry, false, "HTTP \(status) terminal")
            try expectEqual(decision.category, category, "HTTP \(status) category")
        }
    }

    private static func respectsShortRetryAfter() throws {
        let decision = makePolicy().decision(
            for: CloudTranscriptionHTTPFailure(
                statusCode: 429,
                retryAfterSeconds: 12,
                providerCode: "rate_limit_exceeded"
            ),
            completedAttemptCount: 2
        )
        try expectEqual(decision.shouldRetry, true, "Retry-After retry")
        try expectEqual(decision.delaySeconds, 12, "Retry-After delay")

        let tooLong = makePolicy().decision(
            for: CloudTranscriptionHTTPFailure(
                statusCode: 429,
                retryAfterSeconds: 61,
                providerCode: "rate_limit_exceeded"
            ),
            completedAttemptCount: 1
        )
        try expectEqual(tooLong.shouldRetry, false, "long Retry-After terminal")
        try expectEqual(tooLong.category, .rateLimited, "long Retry-After category")
    }

    private static func treatsQuotaAndAuthenticationAsTerminal() throws {
        let policy = makePolicy()
        let quota = policy.decision(
            for: CloudTranscriptionHTTPFailure(
                statusCode: 429,
                providerCode: "insufficient_quota",
                providerType: "insufficient_quota"
            ),
            completedAttemptCount: 1
        )
        try expectEqual(quota.shouldRetry, false, "quota terminal")
        try expectEqual(quota.category, .quotaExhausted, "quota category")
    }

    private static func stopsAfterRetryBudgetIsExhausted() throws {
        let decision = makePolicy().decision(
            for: URLError(.timedOut),
            completedAttemptCount: 3
        )
        try expectEqual(decision.shouldRetry, false, "retry budget terminal")
        try expectEqual(decision.category, .retryExhausted, "retry budget category")
        try expectEqual(decision.delaySeconds, nil, "retry budget delay")
    }

    private static func calculatesSizeAwareAttemptTimeout() throws {
        let policy = makePolicy()
        try expectEqual(
            policy.attemptTimeout(
                encodedByteCount: 0,
                minimum: 20,
                maximum: 300
            ),
            20,
            "base timeout"
        )
        try expectEqual(
            policy.attemptTimeout(
                encodedByteCount: 131_072,
                minimum: 30,
                maximum: 300
            ),
            30,
            "configured minimum"
        )
        try expectEqual(
            policy.attemptTimeout(
                encodedByteCount: 131_072 * 400,
                minimum: 20,
                maximum: 300
            ),
            300,
            "timeout cap"
        )
    }

    private static func makePolicy() -> CloudTranscriptionRetryPolicy {
        CloudTranscriptionRetryPolicy(
            maximumAttempts: 3,
            jitter: { _ in 0.25 }
        )
    }

    private static func expectEqual<T: Equatable>(
        _ actual: T,
        _ expected: T,
        _ label: String
    ) throws {
        guard actual == expected else {
            throw TestFailure("\(label): expected \(expected), got \(actual)")
        }
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
