import Foundation
import Security

enum CredentialStoreError: LocalizedError {
    case writeFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .writeFailed(let underlying):
            underlying.localizedDescription
        }
    }
}

/// Where provider API keys are kept. `load` returns nil when no key is
/// stored and throws only when the store itself can't be read; `save`
/// replaces an existing key in place.
protocol CredentialSecretStore: Sendable {
    func load(account: String) throws -> String?
    func save(_ value: String, account: String) throws
    func delete(account: String) throws
}

/// Provider API keys in the login Keychain: one generic-password item per
/// key, all under the service `<bundle id>.api-keys`.
struct KeychainCredentialSecretStore: CredentialSecretStore {
    let service: String

    static var live: KeychainCredentialSecretStore {
        KeychainCredentialSecretStore(
            service: (Bundle.main.bundleIdentifier ?? "com.woosublee.quill") + ".api-keys"
        )
    }

    private func itemQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    func load(account: String) throws -> String? {
        var query = itemQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError(status: status)
        }
        return String(data: data, encoding: .utf8)
    }

    func save(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let query = itemQuery(account: account)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
        var insert = query
        insert[kSecValueData as String] = data
        let insertStatus = SecItemAdd(insert as CFDictionary, nil)
        guard insertStatus == errSecSuccess else {
            throw KeychainError(status: insertStatus)
        }
    }

    func delete(account: String) throws {
        let status = SecItemDelete(itemQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    struct KeychainError: LocalizedError {
        let status: OSStatus

        var errorDescription: String? {
            "Keychain operation failed with status \(status)"
        }
    }
}

/// The instance-owned location of Quill's credential settings file, and
/// the store that holds provider API keys.
struct CredentialStorageLayout: Sendable {
    let directory: URL
    let secrets: any CredentialSecretStore

    static var live: CredentialStorageLayout {
        CredentialStorageLayout(
            directory: AppName.applicationSupportDirectory,
            secrets: KeychainCredentialSecretStore.live
        )
    }
}

struct CredentialStore: Sendable {
    let layout: CredentialStorageLayout

    /// Settings accounts that hold API keys, and the Keychain account each
    /// one is kept under. Base URLs and other settings stay in the file.
    static let keychainAccounts: [String: String] = [
        "groq_api_key": "provider",
        "transcription_api_key": "transcription-provider"
    ]

    private var settingsFileURL: URL {
        layout.directory.appendingPathComponent(".settings")
    }

    func load(account: String) -> String? {
        let fileValue = loadSettings()[account]
        guard let keychainAccount = Self.keychainAccounts[account] else {
            return fileValue
        }
        let stored: String?
        do {
            stored = try layout.secrets.load(account: keychainAccount)
        } catch {
            // A Keychain that can't be read leaves the file copy in place
            // and in use, so the key isn't lost.
            return fileValue
        }
        if let stored {
            if fileValue != nil { removeFileValue(account: account) }
            return stored
        }
        guard let fileValue else { return nil }
        // Move a key saved by an earlier version into the Keychain. The
        // file copy is removed only after the Keychain reads it back.
        if (try? layout.secrets.save(fileValue, account: keychainAccount)) != nil,
           (try? layout.secrets.load(account: keychainAccount)) == fileValue {
            removeFileValue(account: account)
        }
        return fileValue
    }

    func save(_ value: String, account: String) throws {
        if let keychainAccount = Self.keychainAccounts[account] {
            do {
                try layout.secrets.save(value, account: keychainAccount)
            } catch {
                throw CredentialStoreError.writeFailed(underlying: error)
            }
            removeFileValue(account: account)
            return
        }
        var dict = loadSettings()
        dict[account] = value
        try writeSettings(dict)
    }

    func delete(account: String) throws {
        var dict = loadSettings()
        guard let keychainAccount = Self.keychainAccounts[account] else {
            dict.removeValue(forKey: account)
            try writeSettings(dict)
            return
        }
        // Remove any file copy first: one left behind would be moved back
        // into the Keychain on the next load.
        if dict.removeValue(forKey: account) != nil {
            try writeSettings(dict)
        }
        do {
            try layout.secrets.delete(account: keychainAccount)
        } catch {
            throw CredentialStoreError.writeFailed(underlying: error)
        }
    }

    /// Best effort: a copy left behind is removed on the next load.
    private func removeFileValue(account: String) {
        var dict = loadSettings()
        guard dict.removeValue(forKey: account) != nil else { return }
        try? writeSettings(dict)
    }

    private func prepareDirectory() {
        let directory = layout.directory
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
    }

    private func loadSettings() -> [String: String] {
        let url = settingsFileURL
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return dict
    }

    private func writeSettings(_ dict: [String: String]) throws {
        prepareDirectory()
        let url = settingsFileURL
        do {
            let data = try JSONEncoder().encode(dict)
            try data.write(to: url, options: [.atomic])
        } catch {
            throw CredentialStoreError.writeFailed(underlying: error)
        }
        // Restrict to owner-only read/write (0600). Best-effort: the value
        // is already durably written above, so a permission-hardening
        // failure here must not be reported as a write failure.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
}
