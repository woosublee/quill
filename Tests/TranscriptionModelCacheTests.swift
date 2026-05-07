import Foundation

@main
struct TranscriptionModelCacheTests {
    static func main() throws {
        try testAppleSpeechIsAlwaysInstalled()
        try testCacheDirectoryNameUsesHuggingFaceConvention()
        try testSnapshotWeightsNPZMarksModelInstalled()
        try testSnapshotWeightsSafetensorsMarksModelInstalled()
        try testLargeBlobMarksModelInstalled()
        try testDeleteRemovesOnlySelectedModelCache()
        try testDeleteRejectsAppleSpeech()
        try testDeleteMissingCacheSucceeds()
        try testPythonDownloaderUsesSiblingPythonForSymlinkedWhisperBinary()
        try testPythonDownloaderPreservesEnvShebangArguments()
        try testDownloadProgressCountsCachedBytes()
        try testZeroByteDownloadProgressUsesStartingLabel()
        try testDownloadTaskCancelTerminatesAttachedProcess()
        print("TranscriptionModelCacheTests passed")
    }

    private static func testAppleSpeechIsAlwaysInstalled() throws {
        assert(TranscriptionModel.find(id: "apple-speech").isInstalled(in: temporaryHubRoot()))
    }

    private static func testCacheDirectoryNameUsesHuggingFaceConvention() throws {
        let model = TranscriptionModel.find(id: "mlx-community/whisper-large-v3-turbo")

        assert(model.cacheDirectoryName == "models--mlx-community--whisper-large-v3-turbo")
        assert(model.cacheDirectory(in: URL(fileURLWithPath: "/tmp/hub")).path == "/tmp/hub/models--mlx-community--whisper-large-v3-turbo")
    }

    private static func testSnapshotWeightsNPZMarksModelInstalled() throws {
        let hubRoot = temporaryHubRoot()
        defer { try? FileManager.default.removeItem(at: hubRoot) }
        let model = TranscriptionModel.find(id: "mlx-community/whisper-large-v3-mlx")
        let snapshot = model.cacheDirectory(in: hubRoot)
            .appendingPathComponent("snapshots")
            .appendingPathComponent("revision")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: snapshot.appendingPathComponent("weights.npz").path, contents: Data())

        assert(model.isInstalled(in: hubRoot))
    }

    private static func testSnapshotWeightsSafetensorsMarksModelInstalled() throws {
        let hubRoot = temporaryHubRoot()
        defer { try? FileManager.default.removeItem(at: hubRoot) }
        let model = TranscriptionModel.find(id: "mlx-community/whisper-large-v3-turbo")
        let snapshot = model.cacheDirectory(in: hubRoot)
            .appendingPathComponent("snapshots")
            .appendingPathComponent("revision")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: snapshot.appendingPathComponent("weights.safetensors").path, contents: Data())

        assert(model.isInstalled(in: hubRoot))
    }

    private static func testLargeBlobMarksModelInstalled() throws {
        let hubRoot = temporaryHubRoot()
        defer { try? FileManager.default.removeItem(at: hubRoot) }
        let model = TranscriptionModel.find(id: "mlx-community/whisper-small-mlx")
        let blobs = model.cacheDirectory(in: hubRoot).appendingPathComponent("blobs")
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        let blob = blobs.appendingPathComponent("large-blob")
        FileManager.default.createFile(atPath: blob.path, contents: Data())
        let handle = try FileHandle(forWritingTo: blob)
        try handle.truncate(atOffset: 100_000_001)
        try handle.close()

        assert(model.isInstalled(in: hubRoot))
    }

    private static func testDeleteRemovesOnlySelectedModelCache() throws {
        let hubRoot = temporaryHubRoot()
        defer { try? FileManager.default.removeItem(at: hubRoot) }
        let selected = TranscriptionModel.find(id: "mlx-community/whisper-large-v3-turbo")
        let unrelated = TranscriptionModel.find(id: "mlx-community/whisper-large-v3-mlx")
        try FileManager.default.createDirectory(at: selected.cacheDirectory(in: hubRoot), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelated.cacheDirectory(in: hubRoot), withIntermediateDirectories: true)

        try selected.deleteCache(in: hubRoot)

        assert(!FileManager.default.fileExists(atPath: selected.cacheDirectory(in: hubRoot).path))
        assert(FileManager.default.fileExists(atPath: unrelated.cacheDirectory(in: hubRoot).path))
    }

    private static func testDeleteRejectsAppleSpeech() throws {
        let model = TranscriptionModel.find(id: "apple-speech")

        do {
            try model.deleteCache(in: temporaryHubRoot())
            assertionFailure("Apple Speech cache deletion should fail")
        } catch TranscriptionModelCacheError.builtInModelCannotBeDeleted {
        } catch {
            assertionFailure("Unexpected error: \(error)")
        }
    }

    private static func testDeleteMissingCacheSucceeds() throws {
        let hubRoot = temporaryHubRoot()
        defer { try? FileManager.default.removeItem(at: hubRoot) }
        let model = TranscriptionModel.find(id: "mlx-community/whisper-medium-mlx")

        try model.deleteCache(in: hubRoot)

        assert(!FileManager.default.fileExists(atPath: model.cacheDirectory(in: hubRoot).path))
    }

    private static func testPythonDownloaderUsesSiblingPythonForSymlinkedWhisperBinary() throws {
        let root = temporaryHubRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let venvBin = root.appendingPathComponent("venv/bin")
        let shimBin = root.appendingPathComponent("shim/bin")
        try FileManager.default.createDirectory(at: venvBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: shimBin, withIntermediateDirectories: true)
        let python = venvBin.appendingPathComponent("python")
        let whisper = venvBin.appendingPathComponent("mlx_whisper")
        let shim = shimBin.appendingPathComponent("mlx_whisper")
        FileManager.default.createFile(atPath: python.path, contents: Data())
        FileManager.default.createFile(atPath: whisper.path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
        try FileManager.default.createSymbolicLink(at: shim, withDestinationURL: whisper)

        let invocation = TranscriptionModel.pythonInvocation(for: shim.path, homeDirectory: home, fileManager: .default)

        assert(invocation?.executableURL == python)
        assert(invocation?.arguments.isEmpty == true)
    }

    private static func testPythonDownloaderPreservesEnvShebangArguments() throws {
        let root = temporaryHubRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let whisper = bin.appendingPathComponent("mlx_whisper")
        try "#!/usr/bin/env -S python3 -I\n".write(to: whisper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: whisper.path)

        let invocation = TranscriptionModel.pythonInvocation(for: whisper.path, homeDirectory: home, fileManager: .default)

        assert(invocation?.executableURL.path == "/usr/bin/env")
        assert(invocation?.arguments == ["-S", "python3", "-I"])
    }

    private static func testDownloadProgressCountsCachedBytes() throws {
        let hubRoot = temporaryHubRoot()
        defer { try? FileManager.default.removeItem(at: hubRoot) }
        let model = TranscriptionModel.find(id: "mlx-community/whisper-large-v3-turbo")
        let blobs = model.cacheDirectory(in: hubRoot).appendingPathComponent("blobs")
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        let completeBlob = blobs.appendingPathComponent("complete")
        let incompleteBlob = blobs.appendingPathComponent("partial.incomplete")
        FileManager.default.createFile(atPath: completeBlob.path, contents: Data())
        FileManager.default.createFile(atPath: incompleteBlob.path, contents: Data())
        try FileHandle(forWritingTo: completeBlob).truncate(atOffset: 2_000)
        try FileHandle(forWritingTo: incompleteBlob).truncate(atOffset: 3_000)

        let progress = model.downloadProgress(in: hubRoot)

        assert(progress.downloadedBytes == 5_000)
        assert((progress.fractionCompleted ?? 0) > 0)
        assert((progress.fractionCompleted ?? 1) < 1)
    }

    private static func testZeroByteDownloadProgressUsesStartingLabel() throws {
        let progress = TranscriptionModel.DownloadProgress(downloadedBytes: 0, totalBytes: 100)

        assert(progress.displayText == "Starting...")
    }

    private static func testDownloadTaskCancelTerminatesAttachedProcess() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        let task = TranscriptionModel.DownloadTask(process: process)

        task.cancel()
        process.waitUntilExit()

        assert(process.terminationReason == .uncaughtSignal)
    }

    private static func temporaryHubRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-transcription-model-cache-tests")
            .appendingPathComponent(UUID().uuidString)
    }
}
