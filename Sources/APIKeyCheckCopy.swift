import Foundation
import QuillProviderCore

/// What to tell the user when an API key check fails for a reason other than
/// a rejected key. The iPhone shows the same copy.
enum APIKeyCheckCopy {
    static func reason(for result: CloudAPIKeyValidationResult) -> String? {
        switch result {
        case .valid, .rejected:
            return nil
        case .notFound:
            return String(localized: "No API was found at this URL. Check the path at the end, like /openai/v1.")
        case .rateLimited:
            return String(localized: "Too many requests right now. Try again in a moment.")
        case .unreachable, .insecureConnection:
            return String(localized: "Couldn't reach the provider. Check your internet connection and try again.")
        case .invalidURL:
            return String(localized: "Check the API URL. It must start with http or https.")
        }
    }
}
