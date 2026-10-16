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

    static func service(bundleIdentifier: String) -> String {
        bundleIdentifier + ".api-keys"
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
        guard let value = String(data: data, encoding: .utf8) else {
            throw KeychainError(status: errSecDecode)
        }
        return value
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
        insert[kSecAttrLabel as String] = "\(AppName.displayName) API key (\(account))"
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
            SecCopyErrorMessageString(status, nil) as String?
                ?? "Keychain operation failed with status \(status)"
        }
    }
}

/// Used when there is no bundle identifier to name a Keychain service, as
/// in test executables. Every call fails, so keys stay where they are in
/// the settings file: never moved, never removed, never written.
struct UnavailableCredentialSecretStore: CredentialSecretStore {
    struct Unavailable: LocalizedError {
        var errorDescription: String? { "No Keychain service for this process" }
    }

    func load(account: String) throws -> String? { throw Unavailable() }
    func save(_ value: String, account: String) throws { throw Unavailable() }
    func delete(account: String) throws { throw Unavailable() }
}

/// The instance-owned location of Quill's credential settings file, and
/// the store that holds provider API keys.
struct CredentialStorageLayout: Sendable {
    let directory: URL
    let secrets: any CredentialSecretStore

    static var live: CredentialStorageLayout {
        live(bundleIdentifier: Bundle.main.bundleIdentifier)
    }

    static func live(bundleIdentifier: String?) -> CredentialStorageLayout {
        let secrets: any CredentialSecretStore = bundleIdentifier.map {
            KeychainCredentialSecretStore(service: KeychainCredentialSecretStore.service(bundleIdentifier: $0))
        } ?? UnavailableCredentialSecretStore()
        return CredentialStorageLayout(
            directory: AppName.applicationSupportDirectory,
            secrets: secrets
        )
    }
}

struct CredentialStore: Sendable {
    let layout: CredentialStorageLayout

    static let providerAPIKeyAccount = "groq_api_key"
    static let transcriptionAPIKeyAccount = "transcription_api_key"

    /// Settings accounts that hold API keys, and the Keychain account each
    /// one is kept under. Base URLs and other settings stay in the file.
    static let keychainAccounts: [String: String] = [
        providerAPIKeyAccount: "provider",
        transcriptionAPIKeyAccount: "transcription-provider"
    ]

    /// What loading an API key found. `keychainUnreadable` is set when the
    /// Keychain couldn't be read and there was no file copy to fall back on.
    struct LoadResult: Equatable {
        var value: String?
        var keychainUnreadable = false
    }

    private var settingsFileURL: URL {
        layout.directory.appendingPathComponent(".settings")
    }

    func load(account: String) -> String? {
        loadReportingFailure(account: account).value
    }

    func loadReportingFailure(account: String) -> LoadResult {
        let fileValue = loadSettings()[account]
        guard let keychainAccount = Self.keychainAccounts[account] else {
            return LoadResult(value: fileValue)
        }
        let stored: String?
        do {
            stored = try layout.secrets.load(account: keychainAccount)
        } catch {
            // A Keychain that can't be read leaves the file copy in place
            // and in use, so the key isn't lost.
            return LoadResult(value: fileValue, keychainUnreadable: fileValue == nil)
        }
        guard let fileValue else { return LoadResult(value: stored) }
        if fileValue == stored {
            removeFileValue(account: account)
            return LoadResult(value: stored)
        }
        // This version never writes keys to the file, so a file copy that
        // differs is newer: either the first move from an earlier version,
        // or a key entered after going back to one. It replaces the
        // Keychain key, and leaves the file only once the Keychain reads
        // it back.
        if (try? layout.secrets.save(fileValue, account: keychainAccount)) != nil,
           (try? layout.secrets.load(account: keychainAccount)) == fileValue {
            removeFileValue(account: account)
        }
        return LoadResult(value: fileValue)
    }

    func save(_ value: String, account: String) throws {
        var dict = loadSettings()
        guard let keychainAccount = Self.keychainAccounts[account] else {
            dict[account] = value
            try writeSettings(dict)
            return
        }
        // The Keychain first, so a failed write leaves the earlier key in
        // place. Then the file copy must go: a differing file copy counts
        // as newer on the next load, so one left behind would undo this
        // change, and that is reported as a failed save.
        do {
            try layout.secrets.save(value, account: keychainAccount)
        } catch {
            throw CredentialStoreError.writeFailed(underlying: error)
        }
        if dict.removeValue(forKey: account) != nil {
            try writeSettings(dict)
        }
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

    /// Best effort, only once the Keychain holds the same key: a copy left
    /// behind is removed on the next load.
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
