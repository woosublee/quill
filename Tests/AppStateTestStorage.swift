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

/// Keeps API keys in memory so tests never touch the login Keychain.
final class InMemoryCredentialSecretStore: CredentialSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    var failsReads = false
    var failsWrites = false

    var accounts: [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    func load(account: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        if failsReads { throw TestSecretStoreFailure() }
        return values[account]
    }

    func save(_ value: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if failsWrites { throw TestSecretStoreFailure() }
        values[account] = value
    }

    func delete(account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if failsWrites { throw TestSecretStoreFailure() }
        values.removeValue(forKey: account)
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        values.removeAll()
    }
}

struct TestSecretStoreFailure: Error {}
