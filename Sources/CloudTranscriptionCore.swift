import Foundation

struct CloudTranscriptionHTTPFailure: Error, Equatable, Sendable {
    let statusCode: Int
    let retryAfterSeconds: TimeInterval?
    let providerCode: String?
    let providerType: String?
    let sanitizedMessage: String?

    init(
        statusCode: Int,
        retryAfterSeconds: TimeInterval? = nil,
        providerCode: String? = nil,
        providerType: String? = nil,
        sanitizedMessage: String? = nil
    ) {
        self.statusCode = statusCode
        self.retryAfterSeconds = retryAfterSeconds
        self.providerCode = providerCode
        self.providerType = providerType
        self.sanitizedMessage = sanitizedMessage
    }
}

enum CloudTranscriptionFailureCategory: String, Codable, Equatable, Sendable {
    case transientNetwork
    case rateLimited
    case providerUnavailable
    case authentication
    case quotaExhausted
    case invalidRequest
    case payloadTooLarge
    case invalidResponse
    case localIO
    case cancelled
    case retryExhausted
}

struct CloudTranscriptionRetryDecision: Equatable, Sendable {
    let shouldRetry: Bool
    let delaySeconds: TimeInterval?
    let category: CloudTranscriptionFailureCategory
}

struct CloudTranscriptionRetryPolicy: Sendable {
    let maximumAttempts: Int
    let jitter: @Sendable (Int) -> TimeInterval

    func decision(
        for error: Error,
        completedAttemptCount: Int
    ) -> CloudTranscriptionRetryDecision {
        let category = category(for: error)
        let retryable = isRetryable(error: error, category: category)
        guard retryable else {
            return CloudTranscriptionRetryDecision(
                shouldRetry: false,
                delaySeconds: nil,
                category: category
            )
        }
        guard completedAttemptCount < maximumAttempts else {
            return CloudTranscriptionRetryDecision(
                shouldRetry: false,
                delaySeconds: nil,
                category: .retryExhausted
            )
        }

        if let failure = error as? CloudTranscriptionHTTPFailure,
           let retryAfterSeconds = failure.retryAfterSeconds {
            guard retryAfterSeconds >= 0, retryAfterSeconds <= 60 else {
                return CloudTranscriptionRetryDecision(
                    shouldRetry: false,
                    delaySeconds: nil,
                    category: category
                )
            }
            return CloudTranscriptionRetryDecision(
                shouldRetry: true,
                delaySeconds: retryAfterSeconds,
                category: category
            )
        }

        let retryIndex = max(0, completedAttemptCount - 1)
        let baseDelay: TimeInterval = retryIndex == 0 ? 1 : 3
        return CloudTranscriptionRetryDecision(
            shouldRetry: true,
            delaySeconds: baseDelay + max(0, jitter(retryIndex)),
            category: category
        )
    }

    func attemptTimeout(
        encodedByteCount: UInt64,
        minimum: TimeInterval,
        maximum: TimeInterval
    ) -> TimeInterval {
        let calculated = 20 + TimeInterval(encodedByteCount) / 131_072
        return max(minimum, min(calculated, maximum))
    }

    private func category(for error: Error) -> CloudTranscriptionFailureCategory {
        if error is CancellationError {
            return .cancelled
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut,
                 .networkConnectionLost,
                 .notConnectedToInternet,
                 .cannotConnectToHost,
                 .cannotFindHost,
                 .dnsLookupFailed:
                return .transientNetwork
            default:
                return .invalidRequest
            }
        }
        if let failure = error as? CloudTranscriptionHTTPFailure {
            let safeCode = failure.providerCode?.lowercased()
            let safeType = failure.providerType?.lowercased()
            if safeCode == "insufficient_quota" || safeType == "insufficient_quota" {
                return .quotaExhausted
            }
            switch failure.statusCode {
            case 408:
                return .transientNetwork
            case 429:
                return .rateLimited
            case 500..<600:
                return .providerUnavailable
            case 401, 403:
                return .authentication
            case 413:
                return .payloadTooLarge
            case 400, 404, 415, 422:
                return .invalidRequest
            default:
                return .invalidResponse
            }
        }
        return .localIO
    }

    private func isRetryable(
        error: Error,
        category: CloudTranscriptionFailureCategory
    ) -> Bool {
        switch category {
        case .transientNetwork, .providerUnavailable:
            return true
        case .rateLimited:
            guard let failure = error as? CloudTranscriptionHTTPFailure else {
                return false
            }
            let safeCode = failure.providerCode?.lowercased()
            let safeType = failure.providerType?.lowercased()
            return safeCode != "insufficient_quota"
                && safeType != "insufficient_quota"
        default:
            return false
        }
    }
}
