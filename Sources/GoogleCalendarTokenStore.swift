import Foundation
import LocalAuthentication
import Security

struct GoogleCalendarOAuthToken: Codable, Equatable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date
    var accountEmail: String?

    var needsRefresh: Bool {
        Date().addingTimeInterval(60) >= expiresAt
    }
}

enum GoogleCalendarTokenStore {
    private static let service = (Bundle.main.bundleIdentifier ?? "com.woosublee.quill") + ".google-calendar"
    private static let account = "oauth-token"

    static func itemQuery(allowsAuthenticationUI: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if !allowsAuthenticationUI {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
            query[kSecUseAuthenticationUI as String] = "fail"
        }
        return query
    }

    static func loadQuery(allowsAuthenticationUI: Bool) -> [String: Any] {
        var query = itemQuery(allowsAuthenticationUI: allowsAuthenticationUI)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return query
    }

    static func load(allowsAuthenticationUI: Bool = true) -> GoogleCalendarOAuthToken? {
        let query = loadQuery(allowsAuthenticationUI: allowsAuthenticationUI)
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(GoogleCalendarOAuthToken.self, from: data)
    }

    static func save(_ token: GoogleCalendarOAuthToken, allowsAuthenticationUI: Bool = true) throws {
        let data = try JSONEncoder().encode(token)
        let query = itemQuery(allowsAuthenticationUI: allowsAuthenticationUI)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            let insertStatus = SecItemAdd(insert as CFDictionary, nil)
            guard insertStatus == errSecSuccess else {
                throw KeychainError(status: insertStatus)
            }
            return
        }
        throw KeychainError(status: status)
    }

    static func delete(allowsAuthenticationUI: Bool = true) {
        let query = itemQuery(allowsAuthenticationUI: allowsAuthenticationUI)
        SecItemDelete(query as CFDictionary)
    }

    struct KeychainError: LocalizedError {
        let status: OSStatus

        var errorDescription: String? {
            "Keychain operation failed with status \(status)"
        }
    }
}
