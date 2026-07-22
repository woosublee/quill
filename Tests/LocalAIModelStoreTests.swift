import CryptoKit
import Foundation

@main
struct LocalAIModelStoreTests {
    static func main() throws {
        try testOfficialArtifactPathsUseDistinctNamesAndDownloads()
        try testModelURLUsesQualityShardOne()
        try testMissingPackageReportsNotInstalled()
        try testAllValidArtifactsReportReady()
        try testCompletedArtifactWithMissingSiblingReportsPartial()
        try testCompletedAndPartialArtifactsReportSummedProgress()
        try testInvalidArtifactsReportCorruptWithArtifactFilename()
        try testInterruptedReplacementRestoresScopedBackupPackageIdempotently()
        try testValidPackageCleansOnlyRecognizedScopedBackups()
        try testDeleteRemovesOnlySelectedPackageArtifactsAndBackups()
        try testDanglingOfficialEntriesAreReportedAndRemoved()
        try testDeleteMissingPackageSucceeds()
        try testCatalogModelsHaveIndependentStorage()
        print("LocalAIModelStoreTests passed")
    }

    private static func testOfficialArtifactPathsUseDistinctNamesAndDownloads() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalAIModelStore(rootDirectory: root)
        let artifacts = LocalAIModelCatalog.quality.artifacts

        assert(store.modelsDirectory.path == root.appendingPathComponent("LocalAI/Models", isDirectory: true).path)
        assert(store.artifactURL(for: artifacts[0]).lastPathComponent == "qwen2.5-7b-instruct-q4_k_m-00001-of-00002.gguf")
        assert(store.artifactURL(for: artifacts[1]).lastPathComponent == "qwen2.5-7b-instruct-q4_k_m-00002-of-00002.gguf")
        assert(store.artifactURL(for: artifacts[0]) != store.artifactURL(for: artifacts[1]))
        assert(store.partialArtifactURL(for: artifacts[0]).lastPathComponent == "qwen2.5-7b-instruct-q4_k_m-00001-of-00002.gguf.download")
        assert(store.partialArtifactURL(for: artifacts[1]).lastPathComponent == "qwen2.5-7b-instruct-q4_k_m-00002-of-00002.gguf.download")
    }

    private static func testModelURLUsesQualityShardOne() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalAIModelStore(rootDirectory: root)

        assert(store.modelURL(for: LocalAIModelCatalog.quality) == store.artifactURL(for: LocalAIModelCatalog.quality.primaryArtifact))
    }

    private static func testMissingPackageReportsNotInstalled() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalAIModelStore(rootDirectory: root)

        assert(store.installStatus(for: testModel()) == .notInstalled)
    }

    private static func testAllValidArtifactsReportReady() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalAIModelStore(rootDirectory: root)
        let artifacts = [Data(repeating: 1, count: 16), Data(repeating: 2, count: 20)]
        let model = testModel(data: artifacts)
        try writeFinalArtifacts(artifacts, for: model, to: store)

        assert(store.installStatus(for: model) == .ready)
    }

    private static func testCompletedArtifactWithMissingSiblingReportsPartial() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalAIModelStore(rootDirectory: root)
        let artifacts = [Data(repeating: 1, count: 16), Data(repeating: 2, count: 20)]
        let model = testModel(data: artifacts)
        try store.ensureModelsDirectoryExists()
        FileManager.default.createFile(atPath: store.artifactURL(for: model.artifacts[0]).path, contents: artifacts[0])

        assert(store.installStatus(for: model) == .partial(downloadedBytes: 16, expectedBytes: 36))
    }

    private static func testCompletedAndPartialArtifactsReportSummedProgress() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalAIModelStore(rootDirectory: root)
        let artifacts = [Data(repeating: 1, count: 16), Data(repeating: 2, count: 20)]
        let model = testModel(data: artifacts)
        try store.ensureModelsDirectoryExists()
        FileManager.default.createFile(atPath: store.artifactURL(for: model.artifacts[0]).path, contents: artifacts[0])
        FileManager.default.createFile(atPath: store.partialArtifactURL(for: model.artifacts[1]).path, contents: Data(repeating: 3, count: 7))

        assert(store.installStatus(for: model) == .partial(downloadedBytes: 23, expectedBytes: 36))
    }

    private static func testInvalidArtifactsReportCorruptWithArtifactFilename() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalAIModelStore(rootDirectory: root)
        let artifacts = [Data(repeating: 1, count: 16), Data(repeating: 2, count: 20)]
        let model = testModel(data: artifacts)
        try store.ensureModelsDirectoryExists()
        FileManager.default.createFile(atPath: store.artifactURL(for: model.artifacts[0]).path, contents: Data(repeating: 9, count: 16))

        assertCorrupt(store.installStatus(for: model), containing: model.artifacts[0].expectedFileName, and: "checksum mismatch")

        try FileManager.default.removeItem(at: store.artifactURL(for: model.artifacts[0]))
        FileManager.default.createFile(atPath: store.artifactURL(for: model.artifacts[1]).path, contents: Data(repeating: 2, count: 1))

        assertCorrupt(store.installStatus(for: model), containing: model.artifacts[1].expectedFileName, and: "too small")
    }

    private static func testInterruptedReplacementRestoresScopedBackupPackageIdempotently() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalAIModelStore(rootDirectory: root)
        let oldContents = [Data(repeating: 4, count: 16), Data(repeating: 5, count: 20)]
        let model = testModel(id: "recover-selected", data: oldContents)
        let otherContents = [Data(repeating: 6, count: 16), Data(repeating: 7, count: 20)]
        let otherModel = testModel(id: "recover-other", data: otherContents)
        let token = UUID().uuidString
        let otherToken = UUID().uuidString
        try store.ensureModelsDirectoryExists()

        try oldContents[0].write(to: store.backupArtifactURL(for: model.artifacts[0], token: token))
        try Data(repeating: 9, count: 3).write(to: store.artifactURL(for: model.artifacts[0]))
        try oldContents[1].write(to: store.artifactURL(for: model.artifacts[1]))
        try Data(repeating: 8, count: 4).write(to: store.partialArtifactURL(for: model.artifacts[1]))

        for (artifact, contents) in zip(otherModel.artifacts, otherContents) {
            try contents.write(to: store.backupArtifactURL(for: artifact, token: otherToken))
        }
        let unrelated = store.modelsDirectory.appendingPathComponent("recover-selected-not-an-artifact.backup-\(token)")
        try Data([1, 2, 3]).write(to: unrelated)

        try store.recoverInterruptedReplacement(for: model)
        try store.recoverInterruptedReplacement(for: model)

        assert(store.installStatus(for: model) == .ready)
        for (artifact, contents) in zip(model.artifacts, oldContents) {
            let restored = try Data(contentsOf: store.artifactURL(for: artifact))
            assert(restored == contents)
            assert(!directoryEntryExists(at: store.backupArtifactURL(for: artifact, token: token)))
        }
        for artifact in otherModel.artifacts {
            assert(directoryEntryExists(at: store.backupArtifactURL(for: artifact, token: otherToken)))
        }
        assert(directoryEntryExists(at: unrelated))
    }

    private static func testValidPackageCleansOnlyRecognizedScopedBackups() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalAIModelStore(rootDirectory: root)
        let contents = [Data(repeating: 10, count: 16), Data(repeating: 11, count: 20)]
        let model = testModel(id: "cleanup-selected", data: contents)
        let otherModel = testModel(id: "cleanup-other")
        let token = UUID().uuidString
        let otherToken = UUID().uuidString
        try writeFinalArtifacts(contents, for: model, to: store)
        for artifact in model.artifacts {
            try Data([4]).write(to: store.backupArtifactURL(for: artifact, token: token))
        }
        for artifact in otherModel.artifacts {
            try Data([5]).write(to: store.backupArtifactURL(for: artifact, token: otherToken))
        }
        let similarButUnrecognized = store.modelsDirectory.appendingPathComponent(
            "\(model.artifacts[0].expectedFileName).backup-not-a-uuid"
        )
        try Data([6]).write(to: similarButUnrecognized)

        try store.recoverInterruptedReplacement(for: model)

        assert(store.installStatus(for: model) == .ready)
        for artifact in model.artifacts {
            assert(!directoryEntryExists(at: store.backupArtifactURL(for: artifact, token: token)))
        }
        for artifact in otherModel.artifacts {
            assert(directoryEntryExists(at: store.backupArtifactURL(for: artifact, token: otherToken)))
        }
        assert(directoryEntryExists(at: similarButUnrecognized))
    }

    private static func testDeleteRemovesOnlySelectedPackageArtifactsAndBackups() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalAIModelStore(rootDirectory: root)
        let selected = testModel(id: "selected")
        let other = testModel(id: "other")
        let selectedToken = UUID().uuidString
        let otherToken = UUID().uuidString
        try store.ensureModelsDirectoryExists()
        for artifact in selected.artifacts {
            FileManager.default.createFile(atPath: store.artifactURL(for: artifact).path, contents: Data([1]))
            FileManager.default.createFile(atPath: store.partialArtifactURL(for: artifact).path, contents: Data([1]))
            FileManager.default.createFile(
                atPath: store.backupArtifactURL(for: artifact, token: selectedToken).path,
                contents: Data([1])
            )
        }
        for artifact in other.artifacts {
            FileManager.default.createFile(atPath: store.artifactURL(for: artifact).path, contents: Data([2]))
            FileManager.default.createFile(atPath: store.partialArtifactURL(for: artifact).path, contents: Data([2]))
            FileManager.default.createFile(
                atPath: store.backupArtifactURL(for: artifact, token: otherToken).path,
                contents: Data([2])
            )
        }

        try store.deleteModel(selected)

        for artifact in selected.artifacts {
            assert(!directoryEntryExists(at: store.artifactURL(for: artifact)))
            assert(!directoryEntryExists(at: store.partialArtifactURL(for: artifact)))
            assert(!directoryEntryExists(at: store.backupArtifactURL(for: artifact, token: selectedToken)))
        }
        for artifact in other.artifacts {
            assert(directoryEntryExists(at: store.artifactURL(for: artifact)))
            assert(directoryEntryExists(at: store.partialArtifactURL(for: artifact)))
            assert(directoryEntryExists(at: store.backupArtifactURL(for: artifact, token: otherToken)))
        }
    }

    private static func testDanglingOfficialEntriesAreReportedAndRemoved() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalAIModelStore(rootDirectory: root)
        let model = testModel(id: "dangling")
        let token = UUID().uuidString
        try store.ensureModelsDirectoryExists()
        let missingTarget = root.appendingPathComponent("missing-target")
        try FileManager.default.createSymbolicLink(
            at: store.artifactURL(for: model.artifacts[0]),
            withDestinationURL: missingTarget
        )
        try FileManager.default.createSymbolicLink(
            at: store.partialArtifactURL(for: model.artifacts[1]),
            withDestinationURL: missingTarget
        )
        try FileManager.default.createSymbolicLink(
            at: store.backupArtifactURL(for: model.artifacts[0], token: token),
            withDestinationURL: missingTarget
        )
        let unrelated = store.modelsDirectory.appendingPathComponent("unrelated-link")
        try FileManager.default.createSymbolicLink(at: unrelated, withDestinationURL: missingTarget)

        assertCorrupt(
            store.installStatus(for: model),
            containing: model.artifacts[0].expectedFileName,
            and: "not a regular file"
        )

        try store.deleteModel(model)

        assert(!directoryEntryExists(at: store.artifactURL(for: model.artifacts[0])))
        assert(!directoryEntryExists(at: store.partialArtifactURL(for: model.artifacts[1])))
        assert(!directoryEntryExists(at: store.backupArtifactURL(for: model.artifacts[0], token: token)))
        assert(directoryEntryExists(at: unrelated))
    }

    private static func testDeleteMissingPackageSucceeds() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalAIModelStore(rootDirectory: root)
        let model = testModel()

        try store.deleteModel(model)
        try store.deletePartialModel(model)

        assert(store.installStatus(for: model) == .notInstalled)
    }

    private static func testCatalogModelsHaveIndependentStorage() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalAIModelStore(rootDirectory: root)

        assert(store.modelURL(for: LocalAIModelCatalog.quality) != store.modelURL(for: LocalAIModelCatalog.fast))
        assert(store.artifactURL(for: LocalAIModelCatalog.quality.primaryArtifact) != store.artifactURL(for: LocalAIModelCatalog.fast.primaryArtifact))
        assert(store.partialArtifactURL(for: LocalAIModelCatalog.quality.primaryArtifact) != store.partialArtifactURL(for: LocalAIModelCatalog.fast.primaryArtifact))
    }

    private static func writeFinalArtifacts(_ data: [Data], for model: LocalAIModel, to store: LocalAIModelStore) throws {
        try store.ensureModelsDirectoryExists()
        for (artifact, contents) in zip(model.artifacts, data) {
            FileManager.default.createFile(atPath: store.artifactURL(for: artifact).path, contents: contents)
        }
    }

    private static func assertCorrupt(_ status: LocalAIInstallStatus, containing filename: String, and reason: String) {
        guard case .corrupt(let message) = status else {
            assertionFailure("Expected corrupt status, got \(status)")
            return
        }
        assert(message.contains(filename))
        assert(message.contains(reason))
    }

    private static func testModel(id: String = "test-model", data: [Data] = [Data(repeating: 1, count: 16), Data(repeating: 2, count: 20)]) -> LocalAIModel {
        LocalAIModel(
            id: id,
            displayName: "Test Model",
            description: "Small test model package",
            artifacts: data.enumerated().map { index, artifactData in
                LocalAIModelArtifact(
                    downloadURL: URL(string: "https://example.com/\(id)-\(index).gguf")!,
                    expectedFileName: "\(id)-\(index).gguf",
                    approximateBytes: Int64(artifactData.count),
                    checksumSHA256: sha256HexDigest(for: artifactData)
                )
            },
            approximateResidentRAMBytes: 72
        )
    }

    private static func sha256HexDigest(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func directoryEntryExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private static func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-local-ai-model-store-tests-\(UUID().uuidString)", isDirectory: true)
    }
}
