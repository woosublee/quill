import Foundation

#if !QUILL_GROUPED_TEST_RUNNER
@main
#endif
struct TranscriptionServiceLocalAITests {
    static func main() async throws {
        try await routesWAVThroughChunkedLocalAI()
        try await missingModelStopsBeforeAudioPreparation()
        try await convertedImportUsesInMemoryCheckpointAndCleansUp()
        try await runtimeFailureMapsToLocalIssueWithoutContent()
        try await explicitLanguageIsPassedToEveryChunk()
        try await convertedWAVWithExtraChunksIsTranscribed()
        print("TranscriptionServiceLocalAITests passed")
    }

    private static func routesWAVThroughChunkedLocalAI() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // 150 s of constant tone: no silence, so 60 + 60 + 30 s chunks.
        let audio = try writeTone(in: root, seconds: 150)
        let calls = CallLog()
        let execution = makeExecution(
            prepareAudio: { url in .init(fileURL: url, cleanup: {}) },
            transcribeChunk: { url, _, timeout in
                calls.append("frames:\(try frameCount(url)) timeout:\(Int(timeout))")
                return "part"
            }
        )
        let store = RecordingCheckpointStore()
        let service = try makeService(execution: execution, checkpointStore: store)
        let result = try await service.transcribe(fileURL: audio)
        try expectEqual(result.text, "part part part", "joined chunks")
        try expectEqual(
            calls.values(),
            ["frames:960000 timeout:120", "frames:960000 timeout:120", "frames:480000 timeout:120"],
            "60 s cap and fixed local timeout"
        )
        try expectEqual(store.savedCount(), 3, "durable checkpoint used for canonical WAV")
    }

    private static func missingModelStopsBeforeAudioPreparation() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = try writeTone(in: root, seconds: 2)
        let prepared = CallLog()
        let execution = makeExecution(
            isReady: false,
            prepareAudio: { url in prepared.append("prepared"); return .init(fileURL: url, cleanup: {}) },
            transcribeChunk: { _, _, _ in "unused" }
        )
        let service = try makeService(execution: execution, checkpointStore: RecordingCheckpointStore())
        do {
            _ = try await service.transcribe(fileURL: audio)
            throw TestFailure("expected missing model")
        } catch let issue as QuillUserIssueError {
            try expectEqual(issue.record.code, .localModelMissing, "missing model code")
            try expectEqual(issue.record.context.localBackend, "Local AI", "backend label")
        }
        try expectEqual(prepared.values(), [], "no audio preparation")
    }

    private static func convertedImportUsesInMemoryCheckpointAndCleansUp() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("import.mp3")
        try Data("not audio".utf8).write(to: original)
        let converted = try writeTone(in: root, seconds: 3)
        let cleaned = CallLog()
        let execution = makeExecution(
            prepareAudio: { _ in .init(fileURL: converted, cleanup: { cleaned.append("cleanup") }) },
            transcribeChunk: { _, _, _ in "imported" }
        )
        let store = RecordingCheckpointStore()
        let service = try makeService(execution: execution, checkpointStore: store)
        let result = try await service.transcribe(fileURL: original)
        try expectEqual(result.text, "imported", "converted import transcribed")
        try expectEqual(store.savedCount(), 0, "durable store untouched for converted audio")
        try expectEqual(cleaned.values(), ["cleanup"], "converted file cleaned")
    }

    private static func runtimeFailureMapsToLocalIssueWithoutContent() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = try writeTone(in: root, seconds: 2)
        let execution = makeExecution(
            prepareAudio: { url in .init(fileURL: url, cleanup: {}) },
            transcribeChunk: { _, _, _ in throw CloudTranscriptionInvalidResponseFailure() }
        )
        let service = try makeService(execution: execution, checkpointStore: RecordingCheckpointStore())
        do {
            _ = try await service.transcribe(fileURL: audio)
            throw TestFailure("expected failure")
        } catch let issue as QuillUserIssueError {
            try expectEqual(issue.record.code, .localTranscriptionFailed, "failure code")
            try expectEqual(issue.record.context.modelID, "gemma-4-e4b-it", "model id")
        }
    }

    private static func explicitLanguageIsPassedToEveryChunk() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = try writeTone(in: root, seconds: 70)
        let languages = CallLog()
        let execution = makeExecution(
            prepareAudio: { url in .init(fileURL: url, cleanup: {}) },
            transcribeChunk: { _, language, _ in languages.append(language ?? "nil"); return "x" }
        )
        let service = try makeService(
            execution: execution,
            checkpointStore: RecordingCheckpointStore(),
            language: TranscriptionLanguage.find(code: "ko")
        )
        _ = try await service.transcribe(fileURL: audio)
        try expectEqual(languages.values(), ["ko", "ko"], "language on every chunk")
    }

    private static func convertedWAVWithExtraChunksIsTranscribed() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("import.m4a")
        try Data("not audio".utf8).write(to: original)
        // AVAudioFile writes a JUNK chunk before "fmt ", so converted imports
        // are valid PCM16 but not the plain 44-byte canonical layout.
        let canonical = try writeTone(in: root, seconds: 2)
        let tone = try Data(contentsOf: canonical)
        var junked = Data("RIFF".utf8)
        let body = Data("WAVE".utf8) + Data("JUNK".utf8)
            + Data([28, 0, 0, 0]) + Data(count: 28) + tone.dropFirst(12)
        var size = UInt32(body.count).littleEndian
        junked.append(Data(bytes: &size, count: 4))
        junked.append(body)
        let converted = root.appendingPathComponent("converted.wav")
        try junked.write(to: converted)
        let frames = CallLog()
        let execution = makeExecution(
            prepareAudio: { _ in .init(fileURL: converted, cleanup: {}) },
            transcribeChunk: { url, _, _ in
                frames.append("\(try frameCount(url))")
                return "converted"
            }
        )
        let store = RecordingCheckpointStore()
        let service = try makeService(execution: execution, checkpointStore: store)
        let result = try await service.transcribe(fileURL: original)
        try expectEqual(result.text, "converted", "converted import transcribed")
        try expectEqual(frames.values(), ["32000"], "all audio frames sent")
        try expectEqual(store.savedCount(), 0, "converted audio uses in-memory checkpoints")
    }

    // MARK: - Helpers

    private static func makeExecution(
        isReady: Bool = true,
        prepareAudio: @escaping @Sendable (URL) async throws -> NativeWhisperExecutionSnapshot.PreparedAudio,
        transcribeChunk: @escaping @Sendable (URL, String?, TimeInterval) async throws -> String
    ) -> LocalAITranscriptionExecutionSnapshot {
        LocalAITranscriptionExecutionSnapshot(
            modelID: "gemma-4-e4b-it",
            displayName: "Gemma 4 E4B",
            packageDigest: "digest",
            requestFormat: .chatCompletionsInputAudio,
            modelIsReady: { isReady },
            prepareAudio: prepareAudio,
            transcribeChunk: transcribeChunk
        )
    }

    private static func makeService(
        execution: LocalAITranscriptionExecutionSnapshot,
        checkpointStore: RecordingCheckpointStore,
        language: TranscriptionLanguage = .auto
    ) throws -> TranscriptionService {
        let context = CloudTranscriptionExecutionContext(
            historyID: UUID(),
            session: CloudTranscriptionJobSession(historyID: UUID(), token: UUID()),
            checkpointStore: checkpointStore,
            progress: { _ in }
        )
        return try TranscriptionExecutionSnapshot.local(
            LocalTranscriptionExecutionSnapshot(
                model: .default,
                localWhisperPath: nil,
                useLegacyMlxWhisper: false,
                language: language,
                localAIExecution: execution
            ),
            TranscriptionCompletionSnapshot(
                postProcessingEnabled: false,
                outputLanguage: "",
                pressEnterCommandEnabled: false
            )
        ).makeTranscriptionService(cloudExecutionContext: context)
    }

    private static func writeTone(in root: URL, seconds: Int) throws -> URL {
        let frames = seconds * 16_000
        var data = CanonicalPCM16WAV.header(dataByteCount: UInt32(frames * 2))
        var payload = Data(count: frames * 2)
        payload.withUnsafeMutableBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for index in 0..<frames { samples[index] = Int16(littleEndian: 2_000) }
        }
        data.append(payload)
        let url = root.appendingPathComponent("\(UUID().uuidString).wav")
        try data.write(to: url)
        return url
    }

    private static func frameCount(_ url: URL) throws -> Int {
        Int(try CanonicalPCM16WAV.validateFile(at: url).frameCount)
    }

    private static func temporaryRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) throws {
        guard actual == expected else { throw TestFailure("\(label): expected \(expected), got \(actual)") }
    }
}

private final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func append(_ value: String) { lock.lock(); stored.append(value); lock.unlock() }
    func values() -> [String] { lock.lock(); defer { lock.unlock() }; return stored }
}

private final class RecordingCheckpointStore: CloudTranscriptionCheckpointStore, @unchecked Sendable {
    private let lock = NSLock()
    private var saves = 0
    func loadCompatible(identity: CloudTranscriptionJobIdentity) async throws -> CloudTranscriptionCheckpoint? { nil }
    func save(_ checkpoint: CloudTranscriptionCheckpoint) async throws { lock.lock(); saves += 1; lock.unlock() }
    func recordFailure(category: CloudTranscriptionFailureCategory) async throws {}
    func savedCount() -> Int { lock.lock(); defer { lock.unlock() }; return saves }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
