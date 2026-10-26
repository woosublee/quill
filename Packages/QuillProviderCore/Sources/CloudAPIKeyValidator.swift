import Foundation
import QuillProviderCore

/// The API key check result. The Mac shows only pass or fail; the iPhone also
/// tells a rejected key from an unreachable provider. Both use the same request
/// and the same pass rule.
public enum CloudAPIKeyValidationResult: Equatable, Sendable {
    case valid
    case rejected
    case unreachable
    case invalidURL
    /// 404: the base URL path is probably wrong (for example, `/openai/v1` is missing).
    case notFound
    /// 429: rate limited. Trying again later works.
    case rateLimited
    /// iOS blocked an unencrypted http connection (only local network addresses are allowed).
    case insecureConnection
}

/// Checks a key with `GET {base}/models`, a Bearer header, and a 10 s timeout.
/// Only 200 passes. The response body is neither read nor kept.
public struct CloudAPIKeyValidator: Sendable {
    private let transport: LLMAPITransport

    public init(transport: LLMAPITransport = .shared) {
        self.transport = transport
    }

    public func validate(key: String, baseURL: String) async -> CloudAPIKeyValidationResult {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .rejected }
        guard let base = try? CloudProviderURL.normalized(baseURL) else { return .invalidURL }

        var request = URLRequest(url: base.appendingPathComponent("models"))
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")

        do {
            let (_, response) = try await transport.data(for: request)
            switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
            case 200: return .valid
            case 401, 403: return .rejected
            case 404: return .notFound
            case 429: return .rateLimited
            default: return .unreachable
            }
        } catch let error as URLError where error.code == .appTransportSecurityRequiresSecureConnection {
            return .insecureConnection
        } catch {
            return .unreachable
        }
    }
}
