import Foundation
import QuillProviderCore

/// What to tell the user when an API key check fails for a reason other than
/// a rejected key. The keys are shared with the iPhone
/// (`CloudAPIKeyCheckCopy`); only the blocked http URL is the Mac's own.
enum APIKeyCheckCopy {
    static let insecureConnectionKey = "This http URL was blocked. Enter an https URL."

    static func reason(for result: CloudAPIKeyValidationResult) -> String? {
        CloudAPIKeyCheckCopy.failureReasonKey(for: result, insecureConnectionKey: insecureConnectionKey)
            .map { localizedCatalogString($0) }
    }
}
