import Foundation

enum AppSettingsStorage {
    private static let bundleID = Bundle.main.bundleIdentifier ?? "com.woosublee.quill"
    static var storageDirectoryOverride: URL?

    private static var defaultStorageDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent(AppName.displayName, isDirectory: true)
    }

    private static var storageDirectory: URL {
        let dir = storageDirectoryOverride ?? defaultStorageDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var settingsFileURL: URL {
        storageDirectory.appendingPathComponent(".settings")
    }

    // MARK: - Public API

    static func load(account: String) -> String? {
        migrateFromKeychainIfNeeded(account: account)
        let dict = loadSettings()
        return dict[account]
    }

    static func save(_ value: String, account: String) {
        var dict = loadSettings()
        dict[account] = value
        writeSettings(dict)
    }

    static func delete(account: String) {
        var dict = loadSettings()
        dict.removeValue(forKey: account)
        writeSettings(dict)
    }

    // MARK: - File I/O

    private static func loadSettings() -> [String: String] {
        let url = settingsFileURL
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return dict
    }

    private static func writeSettings(_ dict: [String: String]) {
        guard let data = try? JSONEncoder().encode(dict) else { return }
        let url = settingsFileURL
        try? data.write(to: url, options: [.atomic])
        // Restrict to owner-only read/write (0600)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    // MARK: - One-time migration from Keychain

    private static let migrationDoneKey = "keychain_migration_done"

    private static func migrateFromKeychainIfNeeded(account: String) {
        var dict = loadSettings()
        if dict[migrationDoneKey] != nil { return }
        dict[migrationDoneKey] = "true"
        writeSettings(dict)
    }

}
