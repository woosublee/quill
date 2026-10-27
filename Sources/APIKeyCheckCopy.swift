import Foundation
import QuillProviderCore

/// What to tell the user when an API key check fails for a reason other than
/// a rejected key.
enum APIKeyCheckCopy {
    static func reason(for result: CloudAPIKeyValidationResult) -> String? {
        switch result {
        case .valid, .rejected:
            return nil
        case .notFound:
            return String(localized: "No API was found at this URL. Check the path at the end, like /openai/v1.")
        case .rateLimited:
            return String(localized: "Too many requests right now. Try again in a moment.")
        case .unreachable:
            // Also a server error or any status other than 200, 401, 403, 404, or 429.
            return String(localized: "Couldn't reach the provider, or it answered with an error. Try again in a moment.")
        case .insecureConnection:
            return String(localized: "This http URL was blocked. Enter an https URL.")
        case .invalidURL:
            return String(localized: "Check the API URL. Enter an http or https address without a username, password, or anything after ? or #.")
        }
    }
}
