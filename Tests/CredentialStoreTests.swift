import Foundation

#if !QUILL_GROUPED_TEST_RUNNER
@main
#endif
struct CredentialStoreTests {
    static func main() throws {
        try testSaveAndLoadRoundTrips()
        try testLoadReturnsNilForMissingAccount()
        try testDeleteIsIdempotentForMissingAccount()
        try testDeleteRemovesAnExistingValue()
        try testSaveOverwritesAnExistingValue()
        try testTwoStoresWithIndependentLayoutsDoNotShareValues()
        try testSaveThrowsWhenDirectoryIsUnavailable()
        try testDeleteThrowsWhenDirectoryIsUnavailable()
        try testSettingsFileHasOwnerOnlyPermissions()
        try testErrorDescriptionSurfacesTheUnderlyingFailure()
        try testLegacyCredentialBridgeIsRemoved()
        try testAPIKeysAreKeptInTheSecretStoreNotTheFile()
        try testChangingAnAPIKeyReplacesTheStoredKey()
        try testAKeyFromAnEarlierVersionMovesOutOfTheFile()
        try testAFailedMoveKeepsTheFileCopy()
        try testAnUnreadableSecretStoreKeepsTheFileCopy()
        try testDeletingAnAPIKeyRemovesEveryCopy()
        try testLiveAPIKeysUseOneKeychainService()
        try testANewerFileKeyReplacesTheKeychainKey()
        try testAnUnreadableKeychainWithNoFileCopyIsReported()
        try testAPIKeyAccountsMatchTheAppSettings()
        try testWithoutAKeychainServiceTheFileKeyStays()
        try testAStaleFileCopyCantUndoAChangedKey()
        try testAFailedKeychainWriteKeepsTheEarlierKey()
        print("CredentialStoreTests passed")
    }

    private static func testSaveAndLoadRoundTrips() throws {
        try withTemporaryStore { store in
            try store.save("secret-value", account: "test_account")
            let loaded = store.load(account: "test_account")
            try expect(loaded == "secret-value", "loaded value matches the saved value")
        }
    }

    private static func testLoadReturnsNilForMissingAccount() throws {
        try withTemporaryStore { store in
            try expect(
                store.load(account: "missing-\(UUID().uuidString)") == nil,
                "loading an account that was never saved returns nil"
            )
        }
    }

    private static func testDeleteIsIdempotentForMissingAccount() throws {
        try withTemporaryStore { store in
            try store.delete(account: "missing-\(UUID().uuidString)")
        }
    }

    private static func testDeleteRemovesAnExistingValue() throws {
        try withTemporaryStore { store in
            try store.save("to-delete", account: "deletable_account")
            try store.delete(account: "deletable_account")
            try expect(
                store.load(account: "deletable_account") == nil,
                "a deleted account is no longer readable"
            )
        }
    }

    private static func testSaveOverwritesAnExistingValue() throws {
        try withTemporaryStore { store in
            try store.save("first-value", account: "overwritable_account")
            try store.save("second-value", account: "overwritable_account")
            try expect(
                store.load(account: "overwritable_account") == "second-value",
                "saving again overwrites the previous value"
            )
        }
    }

    private static func testTwoStoresWithIndependentLayoutsDoNotShareValues() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("credential-store-independent-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let firstStore = CredentialStore(
            layout: CredentialStorageLayout(
                directory: parent.appendingPathComponent("first", isDirectory: true),
                secrets: InMemoryCredentialSecretStore()
            )
        )
        let secondStore = CredentialStore(
            layout: CredentialStorageLayout(
                directory: parent.appendingPathComponent("second", isDirectory: true),
                secrets: InMemoryCredentialSecretStore()
            )
        )

        try firstStore.save("first-store-value", account: "shared_account_name")
        try secondStore.save("second-store-value", account: "shared_account_name")

        try expect(
            firstStore.load(account: "shared_account_name") == "first-store-value",
            "the first store keeps its own value"
        )
        try expect(
            secondStore.load(account: "shared_account_name") == "second-store-value",
            "the second store keeps its own value independent of the first"
        )
    }

    private static func testSaveThrowsWhenDirectoryIsUnavailable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("credential-store-blocked-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("settings-dir", isDirectory: true)
        // Create a plain file where the settings directory should be, so
        // FileManager cannot create it and any write into it fails.
        try Data().write(to: directory)
        let store = CredentialStore(layout: CredentialStorageLayout(directory: directory, secrets: InMemoryCredentialSecretStore()))

        do {
            try store.save("unwritable", account: "blocked_account")
            throw TestFailure("expected save to throw when its directory cannot be created")
        } catch is CredentialStoreError {
            // expected
        }
    }

    private static func testErrorDescriptionSurfacesTheUnderlyingFailure() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("credential-store-error-description-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("settings-dir", isDirectory: true)
        try Data().write(to: directory)
        let store = CredentialStore(layout: CredentialStorageLayout(directory: directory, secrets: InMemoryCredentialSecretStore()))

        do {
            try store.save("unwritable", account: "blocked_account")
            throw TestFailure("expected save to throw when its directory cannot be created")
        } catch let error as CredentialStoreError {
            let description = error.localizedDescription
            try expect(
                !description.contains("CredentialStoreError"),
                "the error description surfaces the underlying failure, not the generic enum-case fallback"
            )
        }
    }

    private static func testDeleteThrowsWhenDirectoryIsUnavailable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("credential-store-blocked-delete-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let directory = root.appendingPathComponent("settings-dir", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = CredentialStore(layout: CredentialStorageLayout(directory: directory, secrets: InMemoryCredentialSecretStore()))
        try store.save("value", account: "account_to_block")

        // Replace the writable directory with a read-only one so the
        // subsequent rewrite (delete is implemented as a rewrite of the
        // settings dictionary) fails.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: directory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: directory.path
            )
            try? FileManager.default.removeItem(at: root)
        }

        do {
            try store.delete(account: "account_to_block")
            throw TestFailure("expected delete to throw when its directory cannot be written")
        } catch is CredentialStoreError {
            // expected
        }
    }

    private static func testSettingsFileHasOwnerOnlyPermissions() throws {
        try withTemporaryStore { store in
            try store.save("permission-checked-value", account: "permission_account")
            let url = store.layout.directory.appendingPathComponent(".settings")
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
            try expect(
                permissions == 0o600,
                "the settings file is restricted to owner-only read/write"
            )
        }
    }

    private static func testLegacyCredentialBridgeIsRemoved() throws {
        let sourceDirectory = URL(
            fileURLWithPath: "Sources",
            isDirectory: true
        )
        let sourceURLs = try FileManager.default
            .contentsOfDirectory(
                at: sourceDirectory,
                includingPropertiesForKeys: nil
            )
            .filter { $0.pathExtension == "swift" }
        let allSource = try sourceURLs
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
        let legacyTypeName = ["App", "Settings", "Storage"].joined()
        let legacyOverrideName = ["storage", "Directory", "Override"].joined()

        try expect(
            !allSource.contains(legacyTypeName),
            "no production source recreates the legacy credential bridge"
        )
        try expect(
            !allSource.contains(legacyOverrideName),
            "no production source recreates the global credential override"
        )
        try expect(
            !sourceURLs.contains {
                $0.lastPathComponent == "KeychainStorage.swift"
            },
            "the legacy credential bridge source is removed"
        )
        try expect(
            CredentialStorageLayout.live.directory
                == AppName.applicationSupportDirectory,
            "the live credential layout preserves the production path"
        )
    }

    private static func testAPIKeysAreKeptInTheSecretStoreNotTheFile() throws {
        try withSecretBackedStore { store, secrets in
            try store.save("synthetic-provider-key", account: "groq_api_key")
            try store.save("synthetic-transcription-key", account: "transcription_api_key")
            try store.save("https://provider.invalid/v1", account: "api_base_url")

            try expect(
                secrets.accounts == [
                    "provider": "synthetic-provider-key",
                    "transcription-provider": "synthetic-transcription-key"
                ],
                "API keys are kept under their Keychain account names"
            )
            let file = try settingsFileContents(store)
            try expect(
                !file.contains("synthetic-provider-key") && !file.contains("synthetic-transcription-key"),
                "API keys never reach the settings file"
            )
            try expect(file.contains("api_base_url"), "base URLs stay in the settings file")
            try expect(
                store.load(account: "groq_api_key") == "synthetic-provider-key",
                "a saved API key loads back"
            )
        }
    }

    private static func testChangingAnAPIKeyReplacesTheStoredKey() throws {
        try withSecretBackedStore { store, secrets in
            try store.save("synthetic-first-key", account: "groq_api_key")
            try store.save("synthetic-second-key", account: "groq_api_key")
            try expect(
                secrets.accounts == ["provider": "synthetic-second-key"],
                "a changed key replaces the stored one instead of adding another"
            )
        }
    }

    private static func testAKeyFromAnEarlierVersionMovesOutOfTheFile() throws {
        try withSecretBackedStore { store, secrets in
            try writeLegacySettings(store, ["groq_api_key": "synthetic-legacy-key", "api_base_url": "https://provider.invalid/v1"])

            try expect(
                store.load(account: "groq_api_key") == "synthetic-legacy-key",
                "the earlier key still loads"
            )
            try expect(
                secrets.accounts == ["provider": "synthetic-legacy-key"],
                "the earlier key is moved into the Keychain"
            )
            let file = try settingsFileContents(store)
            try expect(!file.contains("synthetic-legacy-key"), "the moved key is removed from the file")
            try expect(file.contains("api_base_url"), "other settings stay in the file")
            try expect(
                store.load(account: "groq_api_key") == "synthetic-legacy-key",
                "loading again reads the Keychain copy"
            )
        }
    }

    private static func testAFailedMoveKeepsTheFileCopy() throws {
        try withSecretBackedStore { store, secrets in
            try writeLegacySettings(store, ["groq_api_key": "synthetic-legacy-key"])
            secrets.failsWrites = true

            try expect(
                store.load(account: "groq_api_key") == "synthetic-legacy-key",
                "the key still loads when the Keychain refuses it"
            )
            let keptFile = try settingsFileContents(store)
            try expect(
                keptFile.contains("synthetic-legacy-key"),
                "the file copy is kept when the move fails"
            )

            secrets.failsWrites = false
            _ = store.load(account: "groq_api_key")
            let retriedFile = try settingsFileContents(store)
            try expect(
                secrets.accounts == ["provider": "synthetic-legacy-key"]
                    && !retriedFile.contains("synthetic-legacy-key"),
                "the move is retried on a later load"
            )
        }
    }

    private static func testAnUnreadableSecretStoreKeepsTheFileCopy() throws {
        try withSecretBackedStore { store, secrets in
            try writeLegacySettings(store, ["groq_api_key": "synthetic-legacy-key"])
            secrets.failsReads = true

            try expect(
                store.load(account: "groq_api_key") == "synthetic-legacy-key",
                "the file copy is used while the Keychain can't be read"
            )
            let file = try settingsFileContents(store)
            try expect(
                file.contains("synthetic-legacy-key"),
                "the file copy is not removed while the Keychain can't be read"
            )
        }
    }

    private static func testDeletingAnAPIKeyRemovesEveryCopy() throws {
        try withSecretBackedStore { store, secrets in
            try store.save("synthetic-provider-key", account: "groq_api_key")
            try writeLegacySettings(store, ["groq_api_key": "synthetic-stale-key"])

            try store.delete(account: "groq_api_key")

            try expect(secrets.accounts.isEmpty, "the Keychain key is removed")
            try expect(
                store.load(account: "groq_api_key") == nil,
                "a stale file copy doesn't come back after a delete"
            )
        }
    }

    private static func testLiveAPIKeysUseOneKeychainService() throws {
        let app = CredentialStorageLayout.live(bundleIdentifier: "com.example.synthetic")
        try expect(
            (app.secrets as? KeychainCredentialSecretStore)?.service == "com.example.synthetic.api-keys",
            "every API key shares the <bundle id>.api-keys Keychain service"
        )
        try expect(
            CredentialStorageLayout.live(bundleIdentifier: nil).secrets is UnavailableCredentialSecretStore,
            "a process without a bundle identifier, like a test, never reaches the Keychain"
        )
        try expect(
            Bundle.main.bundleIdentifier != nil
                || !(CredentialStorageLayout.live.secrets is KeychainCredentialSecretStore),
            "this test executable's live layout stays out of the Keychain"
        )
    }

    private static func testANewerFileKeyReplacesTheKeychainKey() throws {
        try withSecretBackedStore { store, secrets in
            try store.save("synthetic-old-key", account: "groq_api_key")
            // An earlier version, run after the move, saved a new key to the file.
            try writeLegacySettings(store, ["groq_api_key": "synthetic-new-key"])

            try expect(
                store.load(account: "groq_api_key") == "synthetic-new-key",
                "the key entered in the earlier version is used"
            )
            let file = try settingsFileContents(store)
            try expect(
                secrets.accounts == ["provider": "synthetic-new-key"]
                    && !file.contains("synthetic-new-key"),
                "the newer key replaces the Keychain key and leaves the file"
            )
        }
    }

    private static func testAnUnreadableKeychainWithNoFileCopyIsReported() throws {
        try withSecretBackedStore { store, secrets in
            try store.save("synthetic-provider-key", account: "groq_api_key")
            secrets.failsReads = true

            try expect(
                store.loadReportingFailure(account: "groq_api_key")
                    == CredentialStore.LoadResult(value: nil, keychainUnreadable: true),
                "a Keychain that can't be read is reported, not taken as no key"
            )
            try expect(
                store.loadReportingFailure(account: "api_base_url")
                    == CredentialStore.LoadResult(value: nil),
                "settings outside the Keychain are unaffected"
            )
        }
    }

    private static func testWithoutAKeychainServiceTheFileKeyStays() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("credential-store-no-keychain-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CredentialStore(
            layout: CredentialStorageLayout(directory: root, secrets: UnavailableCredentialSecretStore())
        )
        try writeLegacySettings(store, ["groq_api_key": "synthetic-legacy-key"])

        try expect(
            store.load(account: "groq_api_key") == "synthetic-legacy-key",
            "the file key is still read"
        )
        let file = try settingsFileContents(store)
        try expect(
            file.contains("synthetic-legacy-key"),
            "the file key is never moved out when there is no Keychain to hold it"
        )
    }

    private static func testAStaleFileCopyCantUndoAChangedKey() throws {
        try withSecretBackedStore { store, secrets in
            try store.save("synthetic-first-key", account: "groq_api_key")
            try writeLegacySettings(store, ["groq_api_key": "synthetic-stale-key"])
            let directory = store.layout.directory
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }

            do {
                try store.save("synthetic-second-key", account: "groq_api_key")
                throw TestFailure("expected save to fail while the stale file copy can't be removed")
            } catch is CredentialStoreError {
                // expected: the change would be undone on the next load, so it's reported
            }
            try expect(
                secrets.accounts == ["provider": "synthetic-first-key"],
                "a failed save puts the Keychain back to its earlier key"
            )
            try expect(
                store.load(account: "groq_api_key") == "synthetic-stale-key",
                "loading after the failed save gives what it gave before the save"
            )
        }
    }

    private static func testAFailedKeychainWriteKeepsTheEarlierKey() throws {
        try withSecretBackedStore { store, secrets in
            try writeLegacySettings(store, ["groq_api_key": "synthetic-legacy-key"])
            secrets.failsWrites = true

            do {
                try store.save("synthetic-new-key", account: "groq_api_key")
                throw TestFailure("expected save to fail when the Keychain refuses the key")
            } catch is CredentialStoreError {
                // expected
            }
            let file = try settingsFileContents(store)
            try expect(
                file.contains("synthetic-legacy-key"),
                "the earlier key stays in the file when the Keychain write fails"
            )
        }
    }

    private static func testAPIKeyAccountsMatchTheAppSettings() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: "Sources/AppState.swift"), encoding: .utf8)
        try expect(
            source.contains("apiKeyStorageKey = CredentialStore.providerAPIKeyAccount")
                && source.contains("transcriptionAPIKeyStorageKey = CredentialStore.transcriptionAPIKeyAccount"),
            "AppState saves its API keys under the accounts the Keychain mapping knows"
        )
    }

    private static func withSecretBackedStore(
        _ operation: (CredentialStore, InMemoryCredentialSecretStore) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("credential-store-secrets-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let secrets = InMemoryCredentialSecretStore()
        let store = CredentialStore(layout: CredentialStorageLayout(directory: root, secrets: secrets))
        try operation(store, secrets)
    }

    private static func settingsFileURL(_ store: CredentialStore) -> URL {
        store.layout.directory.appendingPathComponent(".settings")
    }

    private static func settingsFileContents(_ store: CredentialStore) throws -> String {
        let url = settingsFileURL(store)
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Writes the settings file the way earlier versions did, keys included.
    private static func writeLegacySettings(_ store: CredentialStore, _ values: [String: String]) throws {
        try FileManager.default.createDirectory(at: store.layout.directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(values).write(to: settingsFileURL(store))
    }

    private static func withTemporaryStore(
        _ operation: (CredentialStore) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("credential-store-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CredentialStore(layout: CredentialStorageLayout(directory: root, secrets: InMemoryCredentialSecretStore()))
        try operation(store)
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ label: String
    ) throws {
        guard condition() else { throw TestFailure(label) }
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
