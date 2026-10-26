import Foundation

/// Checks and normalizes a cloud provider base URL: http or https only, no
/// credentials, query, or fragment, a lowercase host, no default port, and no
/// trailing slash.
public enum CloudProviderURLError: Error, Equatable, Sendable {
    case invalidURL
    case unsupportedScheme
    case missingHost
    case embeddedCredentials
    case queryOrFragment
}

public enum CloudProviderURL {
    /// The default provider. The Mac's `AppState.defaultAPIBaseURL` reads it.
    public static let defaultBaseURL = "https://api.groq.com/openai/v1"

    public static func normalized(_ value: String) throws -> URL {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed) else {
            throw CloudProviderURLError.invalidURL
        }
        guard let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw CloudProviderURLError.unsupportedScheme
        }
        guard components.user == nil, components.password == nil else {
            throw CloudProviderURLError.embeddedCredentials
        }
        guard components.query == nil, components.fragment == nil else {
            throw CloudProviderURLError.queryOrFragment
        }
        guard let host = components.host?.lowercased(), !host.isEmpty else {
            throw CloudProviderURLError.missingHost
        }

        components.scheme = scheme
        components.host = host
        if components.port == defaultPort(for: scheme) {
            components.port = nil
        }
        if components.path == "/" {
            components.path = ""
        } else {
            components.path = components.path.replacingOccurrences(
                of: "/+$",
                with: "",
                options: .regularExpression
            )
        }
        guard let normalizedURL = components.url else {
            throw CloudProviderURLError.invalidURL
        }
        return normalizedURL
    }

    public static func host(of value: String) -> String? {
        (try? normalized(value))?.host
    }

    /// The unit that consent and keys belong to (scheme, host, and port). A
    /// different path is the same provider; a different scheme or port is not.
    public static func origin(of value: String) -> String? {
        guard let url = try? normalized(value), let scheme = url.scheme, let host = url.host else { return nil }
        if let port = url.port { return "\(scheme)://\(host):\(port)" }
        return "\(scheme)://\(host)"
    }

    private static func defaultPort(for scheme: String) -> Int? {
        switch scheme {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }
}
