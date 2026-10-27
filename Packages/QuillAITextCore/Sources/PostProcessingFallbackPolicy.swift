import Foundation

/// When a failed transcript cleanup may be tried once more on the fallback
/// model (#580). Each app first rules out cancellation, network failures,
/// and its own local runtime errors, then asks this about a
/// `PostProcessingError`.
public enum PostProcessingFallbackPolicy {
    public static func isServerError(statusCode: Int) -> Bool {
        (500...599).contains(statusCode)
    }

    /// A network failure (offline, host not found, a timeout before any
    /// reply) is worth retrying only on another host: a local model, or a
    /// cloud model after a local one.
    public static func shouldFallBackAfterNetworkFailure(fromLocal: Bool, toLocal: Bool) -> Bool {
        fromLocal || toLocal
    }

    /// - Parameters:
    ///   - fromLocal: the failed run used a local model.
    ///   - toLocal: the fallback is a local model.
    ///   - retriesEmptyCloudOutput: an empty reply from a cloud model may be
    ///     tried again on the fallback.
    public static func shouldFallBack(
        after error: PostProcessingError,
        fromLocal: Bool,
        toLocal: Bool,
        retriesEmptyCloudOutput: Bool
    ) -> Bool {
        let reachesAnotherHost = shouldFallBackAfterNetworkFailure(fromLocal: fromLocal, toLocal: toLocal)
        switch error {
        case .rateLimited:
            return !fromLocal
        case .requestFailed(let statusCode, _):
            return (!fromLocal && statusCode == 429)
                || isServerError(statusCode: statusCode)
        case .requestTimedOut:
            return reachesAnotherHost
        case .emptyOutput:
            return fromLocal || retriesEmptyCloudOutput
        case .invalidResponse:
            return fromLocal
        case .invalidInput, .contextBudgetExceeded,
             .suspectedInstructionExecution, .outputRejected:
            return false
        }
    }
}
