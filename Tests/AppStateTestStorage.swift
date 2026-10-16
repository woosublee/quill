import Foundation

struct AppStateTestEnvironment {
    let rootDirectory: URL
    let storageLayout: AppStateStorageLayout
    let dependencies: AppStateDependencies
}

@MainActor
enum AppStateTestStorage {
    static func withIsolatedStorage<T>(
        _ operation: (AppStateTestEnvironment) async throws -> T
    ) async throws -> T {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "quill-app-state-tests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )
        let storageLayout = AppStateStorageLayout(rootDirectory: rootDirectory)
        let settingsDirectory = rootDirectory.appendingPathComponent("settings", isDirectory: true)
        var dependencies = AppStateDependencies.live
        dependencies.storageLayout = storageLayout
        dependencies.credentialStorageLayout = CredentialStorageLayout(
            directory: settingsDirectory,
            secrets: InMemoryCredentialSecretStore()
        )
        defer {
            try? FileManager.default.removeItem(at: rootDirectory)
        }
        return try await operation(
            AppStateTestEnvironment(
                rootDirectory: rootDirectory,
                storageLayout: storageLayout,
                dependencies: dependencies
            )
        )
    }
}

extension CredentialStorageLayout {
    /// A throwaway settings folder and in-memory API keys, so a test never
    /// reads or writes the real settings file or login Keychain.
    static func isolatedForTests() -> CredentialStorageLayout {
        CredentialStorageLayout(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("quill-test-credentials-\(UUID().uuidString)", isDirectory: true),
            secrets: InMemoryCredentialSecretStore()
        )
    }
}

/// Keeps API keys in memory so tests never touch the login Keychain.
final class InMemoryCredentialSecretStore: CredentialSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var _failsReads = false
    private var _failsWrites = false

    var failsReads: Bool {
        get { lock.withLock { _failsReads } }
        set { lock.withLock { _failsReads = newValue } }
    }

    var failsWrites: Bool {
        get { lock.withLock { _failsWrites } }
        set { lock.withLock { _failsWrites = newValue } }
    }

    var accounts: [String: String] {
        lock.withLock { values }
    }

    func load(account: String) throws -> String? {
        try lock.withLock {
            if _failsReads { throw TestSecretStoreFailure() }
            return values[account]
        }
    }

    func save(_ value: String, account: String) throws {
        try lock.withLock {
            if _failsWrites { throw TestSecretStoreFailure() }
            values[account] = value
        }
    }

    func delete(account: String) throws {
        try lock.withLock {
            if _failsWrites { throw TestSecretStoreFailure() }
            values.removeValue(forKey: account)
        }
    }

    func removeAll() {
        lock.withLock { values.removeAll() }
    }
}

struct TestSecretStoreFailure: Error {}
