import Foundation
import QuillUserIssueCore

public extension PostProcessingError {
    /// The model the failure is about: a timeout names the model it waited
    /// on, otherwise the configured one.
    internal func effectiveModelID(fallback: String) -> String {
        if case .requestTimedOut(_, let modelID) = self {
            return modelID ?? fallback
        }
        return fallback
    }

    /// The stored issue for a failed cleanup, the same on both apps. A
    /// failed cleanup leaves the raw transcript, so it is a warning.
    func userIssueRecord(
        providerHost: String?,
        modelID: String,
        localBackend: String? = nil,
        operation: QuillUserIssueOperation = .postProcessing
    ) -> QuillUserIssueRecord {
        let statusCode: Int?
        if case .requestFailed(let status, _) = self {
            statusCode = status
        } else {
            statusCode = nil
        }
        return QuillUserIssueRecord(
            code: userIssueCode,
            severity: .warning,
            context: QuillUserIssueContext(
                httpStatus: statusCode,
                providerHost: providerHost,
                providerCode: requestFailureProviderCode,
                modelID: effectiveModelID(fallback: modelID),
                localBackend: localBackend,
                operation: operation,
                postProcessingFailureReason: postProcessingFailureReason,
                requestTimeoutSeconds: requestTimeoutSeconds
            )
        )
    }
}

extension PostProcessingError {
    private var userIssueCode: QuillUserIssueCode {
        switch self {
        case .requestFailed(let statusCode, let providerCode):
            if ProviderDiagnosticCode.normalized(providerCode) == "context_length_exceeded" {
                return .postProcessingFailed
            }
            switch statusCode {
            case 400, 404, 415, 422:
                return .providerConfigurationInvalid
            case 401, 403:
                return .authenticationFailed
            case 408:
                return .requestTimedOut
            case 429:
                return .postProcessingRateLimited
            case 413:
                return .postProcessingPayloadTooLarge
            default:
                return .postProcessingFailed
            }
        case .rateLimited:
            return .postProcessingRateLimited
        case .suspectedInstructionExecution, .outputRejected:
            return .postProcessingGuardFallback
        case .requestTimedOut:
            return .requestTimedOut
        case .invalidResponse, .invalidInput, .contextBudgetExceeded, .emptyOutput:
            return .postProcessingFailed
        }
    }

    private var postProcessingFailureReason: PostProcessingFailureReason? {
        switch self {
        case .requestTimedOut:
            return .requestTimedOut
        case .contextBudgetExceeded:
            return .contextBudgetExceeded
        case .emptyOutput:
            return .emptyOutput
        case .invalidResponse:
            return .invalidResponse
        case .requestFailed:
            switch userIssueCode {
            case .requestTimedOut:
                return .requestTimedOut
            case .postProcessingFailed:
                return ProviderDiagnosticCode.normalized(requestFailureProviderCode)
                    == "context_length_exceeded"
                    ? .contextBudgetExceeded
                    : .serviceRequestFailed
            default:
                return nil
            }
        case .rateLimited, .invalidInput, .suspectedInstructionExecution,
             .outputRejected:
            return nil
        }
    }

    private var requestTimeoutSeconds: TimeInterval? {
        if case .requestTimedOut(let seconds, _) = self {
            return seconds
        }
        return nil
    }

    private var requestFailureProviderCode: String? {
        if case .requestFailed(_, let providerCode) = self {
            return providerCode
        }
        return nil
    }
}

public extension AIProcessingOutcome {
    /// What a failed transcript cleanup records, the same on both apps: a
    /// rejected output keeps the raw transcript for its reason, and other
    /// failures name a timeout, an empty reply, or a general failure.
    static func afterPostProcessingFailure(_ error: Error) -> AIProcessingOutcome {
        switch error as? PostProcessingError {
        case .outputRejected(let reason):
            return .rawFallback(reason: reason)
        case .requestTimedOut:
            return .failed(reason: "request-timed-out")
        case .emptyOutput:
            return .failed(reason: "empty-output")
        default:
            return .failed(reason: "post-processing-failed")
        }
    }
}
