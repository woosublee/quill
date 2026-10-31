import AVFoundation
import CryptoKit
import Foundation
import QuillAudioFormatCore
import QuillUserIssueCore
import QuillProviderCore

#if !QUILL_GROUPED_TEST_RUNNER
@main
#endif
struct TranscriptionServiceCloudChunkingTests {
    static func main() async {
        do {
            try await missingAPIKeyStopsBeforeCloudUpload()
            try await normalizedAPIKeyUsesTrimmedAuthorizationHeader()
            try realtimeMissingAPIKeyStopsBeforeWebSocketCreation()
            try realtimeWebSocketURLStaysFixed()
            try realtimeSessionUpdateStaysFixed()
            try realtimeConnectionRequestCarriesTheKey()
            try await realtimeCommitRaceTimesOutWithoutHanging()
            try await realtimeCommitRaceReturnsResultBeforeTimeout()
            try await smallWAVUsesExistingSingleRequestPath()
            try await smallMP3UsesExistingSingleRequestPath()
            try await cloudVerboseJSONLanguageFlowsIntoResult()
            try await cloudExplicitRequestLanguageDrivesResolutionWhenResponseOmitsLanguage()
            try await cloudSnapshotVariantRequestPreservesConfiguredLanguagePrecedence()
            try await cloudSnapshotExplicitLanguageOverridesVerboseResponseLanguage()
            try await plainTextCloudResponseUsesTranscriptNormalizer()
            try await punctuationOnlyPlainTextResponseIsRejected()
            try await largeCanonicalWAVUsesSequentialBoundedChunks()
            try await largeNonWAVImportIsConvertedAndChunked()
            try await smallNonWAVImportKeepsSingleRequest()
            try await interruptedConvertedImportResumesAfterRelaunch()
            try await importConversionFailureSurfacesAsPreparationIssue()
            try await undecodableLargeImportKeepsSingleRequest()
            try await cancellingImportConversionStopsBeforeUpload()
            try await retryableHTTPFailureRetriesCurrentChunkOnly()
            try await terminalProviderFailuresUseStableIssueRecords()
            try await networkAndTimeoutFailuresUseStableIssueCodes()
            try await invalidSuccessfulResponseUsesStableIssueRecord()
            print("TranscriptionServiceCloudChunkingTests passed")
        } catch {
            fputs("TranscriptionServiceCloudChunkingTests failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func missingAPIKeyStopsBeforeCloudUpload() async throws {
        let recorder = UploadRecorder(results: [.success("must not upload")])
        let service = try makeService(
            apiKey: "  ",
            ceiling: 10_000,
            recorder: recorder,
            checkpointStore: CountingCheckpointStore()
        )
        let missingFile = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp3")

        do {
            _ = try await service.transcribe(fileURL: missingFile)
            throw TestFailure("missing API key must fail")
        } catch let issue as QuillUserIssueError {
            try expectEqual(
                issue.record.code,
                .providerConfigurationInvalid,
                "missing API key issue code"
            )
            try expectEqual(
                issue.record.recoveryAction,
                .openProviderSettings,
                "missing API key recovery action"
            )
        }
        try expectEqual(
            await recorder.uploads().count,
            0,
            "missing API key upload count"
        )
    }

    private static func normalizedAPIKeyUsesTrimmedAuthorizationHeader() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp3")
        try Data(repeating: 0x44, count: 128).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = UploadRecorder(results: [.success("trimmed key")])
        let service = try makeService(
            apiKey: "  \n test-key \t",
            ceiling: 10_000,
            recorder: recorder,
            checkpointStore: CountingCheckpointStore()
        )

        _ = try await service.transcribe(fileURL: url)

        let uploads = await recorder.uploads()
        try expectEqual(uploads.count, 1, "normalized API key upload count")
        try expectEqual(
            uploads[0].authorization,
            "Bearer test-key",
            "normalized API key authorization"
        )
    }

    // How a provider base URL becomes the realtime WebSocket URL.
    private static func realtimeWebSocketURLStaysFixed() throws {
        let cases: [(String, String?)] = [
            ("https://api.groq.com/openai/v1", "wss://api.groq.com/openai/v1/realtime?intent=transcription"),
            (" https://api.openai.com/v1/ ", "wss://api.openai.com/v1/realtime?intent=transcription"),
            ("https://api.example.com", "wss://api.example.com/v1/realtime?intent=transcription"),
            ("http://localhost:8080/v1/chat/completions", "ws://localhost:8080/v1/realtime?intent=transcription"),
            ("https://api.example.com/v1/audio/transcriptions", "wss://api.example.com/v1/realtime?intent=transcription"),
            ("wss://api.example.com/v1/realtime", "wss://api.example.com/v1/realtime?intent=transcription"),
            ("https://api.example.com/v1/realtime?intent=custom&x=1", "wss://api.example.com/v1/realtime?intent=custom&x=1"),
            ("https://api.example.com/v1?region=eu", "wss://api.example.com/v1/realtime?region=eu&intent=transcription"),
            ("ftp://api.example.com/v1", nil),
            ("api.example.com/v1", nil),
        ]
        for (input, expected) in cases {
            try expectEqual(
                RealtimeTranscriptionSession.webSocketURL(baseURL: input)?.absoluteString,
                expected,
                "realtime URL for \(input)"
            )
        }
    }

    private static func realtimeSessionUpdateStaysFixed() throws {
        func json(_ object: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
        }
        try expectEqual(
            try json(RealtimeTranscriptionSession.sessionUpdatePayload(model: " gpt-4o-transcribe ", language: "ko")),
            #"{"session":{"audio":{"input":{"format":{"rate":24000,"type":"audio\/pcm"},"transcription":{"language":"ko","model":"gpt-4o-transcribe"},"turn_detection":null}},"type":"transcription"},"type":"session.update"}"#,
            "session.update with model and language"
        )
        try expectEqual(
            try json(RealtimeTranscriptionSession.sessionUpdatePayload(model: "  ", language: "")),
            #"{"session":{"audio":{"input":{"format":{"rate":24000,"type":"audio\/pcm"},"transcription":{},"turn_detection":null}},"type":"transcription"},"type":"session.update"}"#,
            "session.update leaves out an empty model and language"
        )
    }

    private static func realtimeConnectionRequestCarriesTheKey() throws {
        let request = RealtimeTranscriptionSession.connectionRequest(
            url: URL(string: "wss://provider.invalid/v1/realtime")!,
            key: " synthetic-key\n"
        )
        try expectEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-key", "realtime key header")
        try expectEqual(
            RealtimeTranscriptionSession.connectionRequest(url: URL(string: "wss://provider.invalid")!, key: " ")
                .value(forHTTPHeaderField: "Authorization"),
            nil,
            "no header without a key"
        )
    }

    private static func realtimeMissingAPIKeyStopsBeforeWebSocketCreation() throws {
        let creations = LockedCounter()
        let service = RealtimeTranscriptionService(
            config: RealtimeTranscriptionService.Configuration(
                baseURL: "https://api.example.com/openai/v1",
                apiKey: "\n",
                model: "provider/realtime",
                language: nil
            ),
            makeWebSocketTask: { request in
                creations.increment()
                return URLSession.shared.webSocketTask(with: request)
            }
        )

        do {
            try service.start()
            throw TestFailure("missing realtime API key must fail")
        } catch let issue as QuillUserIssueError {
            try expectEqual(
                issue.record.code,
                .providerConfigurationInvalid,
                "missing realtime API key issue code"
            )
            try expectEqual(
                issue.record.recoveryAction,
                .openProviderSettings,
                "missing realtime API key recovery action"
            )
        }
        try expectEqual(creations.value, 0, "missing realtime WebSocket count")
    }

    // A Realtime server that keeps the socket open but never emits the final
    // committed transcript must not hang the recording-stop flow forever.
    // The race must finish close to its own timeout, not the operation's.
    private static func realtimeCommitRaceTimesOutWithoutHanging() async throws {
        let start = Date()
        do {
            _ = try await AppState.raceRealtimeCommitAgainstTimeout(
                timeoutSeconds: 0.05
            ) {
                try await Task.sleep(for: .seconds(999))
                return "never reached"
            }
            throw TestFailure("expected the commit race to time out")
        } catch let error as RealtimeTranscriptionError {
            guard case .commitTimedOut = error else {
                throw TestFailure("expected commitTimedOut, got \(error)")
            }
        }
        let elapsed = Date().timeIntervalSince(start)
        guard elapsed < 5 else {
            throw TestFailure("commit race took \(elapsed)s, expected it to time out near 0.05s")
        }
    }

    private static func realtimeCommitRaceReturnsResultBeforeTimeout() async throws {
        let text = try await AppState.raceRealtimeCommitAgainstTimeout(
            timeoutSeconds: 5
        ) {
            "fast result"
        }
        try expectEqual(text, "fast result", "commit race result when it finishes first")
    }

    private static func smallWAVUsesExistingSingleRequestPath() async throws {
        UserDefaults.standard.removeObject(forKey: "transcription_timeout_seconds")
        let url = try writeCanonicalWAV(samples: [10, 20, 30])
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = UploadRecorder(results: [.success("short wav")])
        let store = CountingCheckpointStore()
        let progress = ChunkingProgressLog()
        let service = try makeService(
            ceiling: 10_000,
            recorder: recorder,
            checkpointStore: store,
            progress: { progress.record($0) }
        )

        let transcript = try await service.transcribe(fileURL: url)
        try expectEqual(transcript.text, "short wav", "small WAV transcript")
        let uploads = await recorder.uploads()
        try expectEqual(uploads.count, 1, "small WAV upload count")
        try expectEqual(uploads[0].timeout, 20, "small WAV timeout")
        try expectContains(uploads[0].body, "filename=\"\(url.lastPathComponent)\"", "small WAV filename")
        try expectContains(uploads[0].body, "Content-Type: audio/wav", "small WAV content type")
        try expectContains(uploads[0].body, "name=\"model\"\r\n\r\nwhisper-large-v3", "small WAV model")
        try expectContains(uploads[0].body, "name=\"language\"\r\n\r\nen", "small WAV language")
        try expectEqual(await store.loadCount(), 0, "small WAV checkpoint load")
        // One request reports no progress, so the status shows no bar (#697).
        try expectEqual(progress.values(), [], "small WAV reports no progress")
    }

    private static func smallMP3UsesExistingSingleRequestPath() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp3")
        try Data(repeating: 0x44, count: 128).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = UploadRecorder(results: [.success("short mp3")])
        let store = CountingCheckpointStore()
        let progress = ChunkingProgressLog()
        let service = try makeService(
            ceiling: 10_000,
            recorder: recorder,
            checkpointStore: store,
            progress: { progress.record($0) }
        )

        let transcript = try await service.transcribe(fileURL: url)
        try expectEqual(transcript.text, "short mp3", "small MP3 transcript")
        let uploads = await recorder.uploads()
        try expectEqual(uploads.count, 1, "small MP3 upload count")
        try expectContains(uploads[0].body, "Content-Type: audio/mpeg", "small MP3 content type")
        try expectEqual(await store.loadCount(), 0, "small MP3 checkpoint load")
        try expectEqual(progress.values(), [], "an imported MP3 reports no progress")
    }

    private static func cloudVerboseJSONLanguageFlowsIntoResult() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp3")
        try Data(repeating: 0x44, count: 128).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = UploadRecorder(results: [
            .verboseJSON(text: "회의 전사문", language: "ko")
        ])
        let service = try makeService(
            ceiling: 10_000,
            language: nil,
            recorder: recorder,
            checkpointStore: CountingCheckpointStore()
        )

        let result = try await service.transcribe(fileURL: url)

        try expectEqual(result.text, "회의 전사문", "cloud verbose JSON transcript")
        try expectEqual(result.spokenLanguage.languageCode, "ko", "cloud verbose JSON language")
        try expectEqual(
            result.spokenLanguage.source,
            .engineDetected,
            "cloud verbose JSON language source"
        )
    }

    private static func cloudExplicitRequestLanguageDrivesResolutionWhenResponseOmitsLanguage() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp3")
        try Data(repeating: 0x44, count: 128).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = UploadRecorder(results: [.success("12345 ---")])
        let service = try makeService(
            ceiling: 10_000,
            language: "ko",
            recorder: recorder,
            checkpointStore: CountingCheckpointStore()
        )

        let result = try await service.transcribe(fileURL: url)

        try expectEqual(result.spokenLanguage.languageCode, "ko", "explicit request language")
        try expectEqual(result.spokenLanguage.source, .configured, "explicit request language source")
        let uploads = await recorder.uploads()
        try expectContains(
            uploads[0].body,
            "name=\"language\"\r\n\r\nko",
            "explicit request language is preserved in upload"
        )
    }

    private static func cloudSnapshotVariantRequestPreservesConfiguredLanguagePrecedence() async throws {
        for (language, result) in [
            ("pt-BR", UploadRecorder.ScriptedResult.success("12345 ---")),
            ("pt-PT", UploadRecorder.ScriptedResult.verboseJSON(text: "English transcript", language: "en"))
        ] {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("mp3")
            try Data(repeating: 0x44, count: 128).write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            let recorder = UploadRecorder(results: [result])
            let cloud = try CloudTranscriptionExecutionSnapshot(
                baseURL: "https://provider.example/v1",
                apiKey: "test-key",
                model: "whisper-large-v3",
                language: language,
                encodedUploadCeilingBytes: 10_000
            )
            let service = try TranscriptionExecutionSnapshot.cloud(
                cloud,
                TranscriptionCompletionSnapshot(
                    postProcessingEnabled: false,
                    outputLanguage: "",
                    pressEnterCommandEnabled: false
                )
            ).makeTranscriptionService(
                cloudDependencies: CloudTranscriptionDependencies(
                    encodedUploadCeilingBytes: 10_000,
                    upload: { request, body in
                        try await recorder.upload(request: request, body: body)
                    },
                    checkpointStore: CountingCheckpointStore(),
                    progress: { _ in },
                    temporaryRoot: FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString, isDirectory: true),
                    sleep: { _ in }
                )
            )

            let transcription = try await service.transcribe(fileURL: url)

            try expectEqual(
                transcription.spokenLanguage.languageCode,
                "pt",
                "\(language) snapshot configured language"
            )
            try expectEqual(
                transcription.spokenLanguage.source,
                .configured,
                "\(language) snapshot configured language source"
            )
            let uploads = await recorder.uploads()
            try expectContains(
                uploads[0].body,
                "name=\"language\"\r\n\r\n\(language)",
                "\(language) request language stays unnormalized"
            )
        }
    }

    private static func cloudSnapshotExplicitLanguageOverridesVerboseResponseLanguage() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp3")
        try Data(repeating: 0x44, count: 128).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = UploadRecorder(results: [
            .verboseJSON(text: "English transcript", language: "en")
        ])
        let cloud = try CloudTranscriptionExecutionSnapshot(
            baseURL: "https://provider.example/v1",
            apiKey: "test-key",
            model: "whisper-large-v3",
            language: "ko",
            encodedUploadCeilingBytes: 10_000
        )
        let service = try TranscriptionExecutionSnapshot.cloud(
            cloud,
            TranscriptionCompletionSnapshot(
                postProcessingEnabled: false,
                outputLanguage: "",
                pressEnterCommandEnabled: false
            )
        ).makeTranscriptionService(
            cloudDependencies: CloudTranscriptionDependencies(
                encodedUploadCeilingBytes: 10_000,
                upload: { request, body in
                    try await recorder.upload(request: request, body: body)
                },
                checkpointStore: CountingCheckpointStore(),
                progress: { _ in },
                temporaryRoot: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true),
                sleep: { _ in }
            )
        )

        let result = try await service.transcribe(fileURL: url)

        try expectEqual(result.spokenLanguage.languageCode, "ko", "cloud snapshot configured language")
        try expectEqual(result.spokenLanguage.source, .configured, "cloud snapshot configured language source")
    }

    private static func plainTextCloudResponseUsesTranscriptNormalizer() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp3")
        try Data(repeating: 0x44, count: 128).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = UploadRecorder(results: [.rawSuccess(" Wait...  really?! \n")])
        let service = try makeService(
            ceiling: 10_000,
            recorder: recorder,
            checkpointStore: CountingCheckpointStore()
        )

        let result = try await service.transcribe(fileURL: url)

        try expectEqual(
            result.text,
            "Wait. really?!",
            "plain-text cloud transcript uses shared normalization"
        )
    }

    private static func punctuationOnlyPlainTextResponseIsRejected() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp3")
        try Data(repeating: 0x44, count: 128).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = UploadRecorder(results: [.rawSuccess("...?!")])
        let service = try makeService(
            ceiling: 10_000,
            recorder: recorder,
            checkpointStore: CountingCheckpointStore()
        )

        do {
            _ = try await service.transcribe(fileURL: url)
            throw TestFailure("punctuation-only plain-text response must fail")
        } catch let issue as QuillUserIssueError {
            try expectEqual(
                issue.record.code,
                .invalidProviderResponse,
                "punctuation-only plain text uses invalid response issue"
            )
        }
    }

    private static func largeCanonicalWAVUsesSequentialBoundedChunks() async throws {
        let multipart = CloudTranscriptionMultipartLayout(
            model: "whisper-large-v3",
            responseFormat: "verbose_json",
            language: nil,
            boundaryByteCount: 36
        )
        let ceiling = try multipart.encodedByteCount(
            audioDataByteCount: CanonicalPCM16WAV.headerByteCount + 4,
            fileName: CloudTranscriptionChunkPlanner.uploadFileName,
            contentType: "audio/wav"
        )
        let url = try writeCanonicalWAV(samples: [1, 1, 2, 2, 3, 3])
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = UploadRecorder(results: [
            .verboseJSON(text: "zero", language: "ko"),
            .success("one"),
            .success("two")
        ])
        let store = CountingCheckpointStore()
        let progress = ChunkingProgressLog()
        let service = try makeService(
            ceiling: ceiling,
            language: nil,
            recorder: recorder,
            checkpointStore: store,
            progress: { progress.record($0) }
        )

        let transcript = try await service.transcribe(fileURL: url)
        try expectEqual(transcript.text, "zero one two", "large ordered transcript")
        // Chunked: it says progress is coming before reading and planning
        // the audio, so the bar shows from the start (#697).
        try expectEqual(
            Array(progress.values().prefix(2)),
            [.preparing, .planned(completed: 0, total: 3)],
            "large WAV announces progress first"
        )
        try expectEqual(transcript.spokenLanguage.languageCode, "ko", "large detected language")
        try expectEqual(transcript.spokenLanguage.source, .engineDetected, "large detected language source")
        let uploads = await recorder.uploads()
        try expectEqual(uploads.count, 3, "large upload count")
        try expectEqual(await recorder.maximumConcurrentUploads(), 1, "sequential upload count")
        guard uploads.allSatisfy({ UInt64($0.body.count) <= ceiling }) else {
            throw TestFailure("every multipart body must fit the encoded ceiling")
        }
        try expectEqual(await store.savedPrefixCounts(), [1, 2, 3], "large checkpoint prefixes")
    }

    // #735: an import over the upload ceiling that isn't canonical WAV is
    // converted to a temporary canonical WAV and sent in bounded chunks.
    private static func largeNonWAVImportIsConvertedAndChunked() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let importURL = try writeSyntheticCAF(in: directory, name: "import.caf")
        let importDigestBefore = try sha256(of: importURL)
        let ceiling = try importChunkCeiling()
        try expectEqual(
            try singleUploadByteCount(for: importURL) > ceiling,
            true,
            "synthetic import exceeds the injected ceiling"
        )
        let recorder = UploadRecorder(results: [
            .success("zero"), .success("one"), .success("two"), .success("three")
        ])
        let progressEvents = ProgressRecorder()
        let temporaryRoot = directory.appendingPathComponent("tmp", isDirectory: true)
        let service = try makeService(
            ceiling: ceiling,
            recorder: recorder,
            checkpointStore: CountingCheckpointStore(),
            temporaryRoot: temporaryRoot,
            progress: { progressEvents.record($0) }
        )

        let transcript = try await service.transcribe(fileURL: importURL)

        let uploads = await recorder.uploads()
        try expectEqual(uploads.count > 1, true, "large import is chunked (uploads: \(uploads.count))")
        guard uploads.allSatisfy({ UInt64($0.body.count) <= ceiling }) else {
            throw TestFailure("every converted chunk must fit the encoded ceiling")
        }
        for upload in uploads {
            try expectContains(upload.body, "Content-Type: audio/wav", "converted chunk is WAV")
        }
        let expectedText = ["zero", "one", "two", "three"].prefix(uploads.count)
            .joined(separator: " ")
        try expectEqual(transcript.text, expectedText, "converted chunks join in order")
        let events = progressEvents.events()
        // Like a large WAV, it says progress is coming before converting
        // and planning, so the bar shows from the start (#697).
        try expectEqual(
            Array(events.prefix(2)),
            [.preparing, .planned(completed: 0, total: uploads.count)],
            "converted import announces progress, then its plan"
        )
        try expectEqual(
            events.last,
            .completed(total: uploads.count),
            "converted import reports completion"
        )
        try expectEqual(try sha256(of: importURL), importDigestBefore, "stored import is unchanged")
        try expectEqual(
            try leftoverFiles(in: temporaryRoot),
            [],
            "converted copy is removed after the job"
        )
    }

    private static func smallNonWAVImportKeepsSingleRequest() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let importURL = try writeSyntheticCAF(in: directory, name: "small.caf", frameCount: 480)
        let recorder = UploadRecorder(results: [.success("small import")])
        let service = try makeService(
            ceiling: try singleUploadByteCount(for: importURL),
            recorder: recorder,
            checkpointStore: CountingCheckpointStore()
        )

        let transcript = try await service.transcribe(fileURL: importURL)

        let uploads = await recorder.uploads()
        try expectEqual(uploads.count, 1, "small import upload count")
        try expectContains(uploads[0].body, "filename=\"small.caf\"", "small import is sent as stored")
        try expectEqual(transcript.text, "small import", "small import transcript")
    }

    // A force-quit mid-way leaves the durable job; after relaunch the
    // reconciler matches it to the stored import and the next run converts
    // again and sends only the chunks still missing.
    private static func interruptedConvertedImportResumesAfterRelaunch() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioRoot = directory.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audioRoot, withIntermediateDirectories: true)
        let importURL = try writeSyntheticCAF(in: audioRoot, name: "meeting.caf")
        let temporaryRoot = directory.appendingPathComponent("tmp", isDirectory: true)
        let store = CloudTranscriptionJobStore(
            jobsDirectory: directory.appendingPathComponent("jobs", isDirectory: true),
            temporaryRoot: temporaryRoot
        )
        let historyID = UUID()
        let policy = CloudTranscriptionCompletionPolicy(
            postProcessingEnabled: false,
            outputLanguage: "",
            pressEnterCommandEnabled: false
        )
        let ceiling = try importChunkCeiling()

        func context() -> CloudTranscriptionExecutionContext {
            let session = store.beginSession(historyID: historyID)
            return CloudTranscriptionExecutionContext(
                historyID: historyID,
                session: session,
                checkpointStore: store.checkpointStore(session: session, completionPolicy: policy),
                progress: { _ in }
            )
        }

        let firstRecorder = UploadRecorder(results: [.success("zero"), .hang])
        let firstService = try makeService(
            ceiling: ceiling,
            recorder: firstRecorder,
            checkpointStore: CountingCheckpointStore(),
            temporaryRoot: temporaryRoot,
            cloudExecutionContext: context()
        )
        let firstRun = Task { try await firstService.transcribe(fileURL: importURL) }
        try await waitUntil("second chunk upload starts") {
            await firstRecorder.uploads().count == 2
        }
        firstRun.cancel()
        do {
            _ = try await firstRun.value
            throw TestFailure("interrupted import must not finish")
        } catch is CancellationError {}

        let saved = try store.load(historyID: historyID)
        guard let saved else { throw TestFailure("interrupted import keeps its job") }
        try expectEqual(saved.completedChunks.count, 1, "interrupted job keeps the finished chunk")
        try expectEqual(
            saved.identity.source.storedAudioFileName,
            "meeting.caf",
            "job names the stored import"
        )
        try expectEqual(try leftoverFiles(in: temporaryRoot), [], "interrupted copy is removed")

        let item = PipelineHistoryItem(
            id: historyID,
            timestamp: Date(timeIntervalSince1970: 1_000),
            rawTranscript: "",
            postProcessedTranscript: "",
            postProcessingPrompt: nil,
            contextSummary: "",
            contextScreenshotDataURL: nil,
            contextScreenshotStatus: "",
            postProcessingStatus: "cloud-transcribing",
            debugStatus: "",
            customVocabulary: "",
            audioFileName: "meeting.caf"
        )
        let reconciliation = store.reconcile(history: [item], audioRoot: audioRoot)
        try expectEqual(
            reconciliation.resumable.map(\.historyID),
            [historyID],
            "relaunch finds the converted import's job resumable"
        )

        let remaining = saved.plan.chunks.count - 1
        let secondRecorder = UploadRecorder(
            results: ["one", "two", "three", "four"].prefix(remaining).map { .success($0) }
        )
        let secondService = try makeService(
            ceiling: ceiling,
            recorder: secondRecorder,
            checkpointStore: CountingCheckpointStore(),
            temporaryRoot: temporaryRoot,
            cloudExecutionContext: context()
        )
        let resumed = try await secondService.transcribe(fileURL: importURL)
        try expectEqual(await secondRecorder.uploads().count, remaining, "resume sends only the missing chunks")
        try expectEqual(
            resumed.text,
            (["zero"] + ["one", "two", "three", "four"].prefix(remaining)).joined(separator: " "),
            "resumed transcript keeps the saved chunk"
        )

        // An edited stored file no longer matches the job.
        try Data(repeating: 0x11, count: 64).write(to: importURL)
        try expectEqual(
            store.reconcile(history: [item], audioRoot: audioRoot).invalid,
            [historyID],
            "a changed stored import invalidates the job"
        )
    }

    private static func importConversionFailureSurfacesAsPreparationIssue() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let importURL = try writeSyntheticCAF(in: directory, name: "broken.caf")
        let temporaryRoot = directory.appendingPathComponent("tmp", isDirectory: true)
        let recorder = UploadRecorder(results: [])
        let service = try makeService(
            ceiling: try importChunkCeiling(),
            recorder: recorder,
            checkpointStore: CountingCheckpointStore(),
            temporaryRoot: temporaryRoot,
            audioPreparation: AudioImportConversionService(convert: { _ in
                throw AudioImportConversionError.conversionFailed("synthetic")
            })
        )

        do {
            _ = try await service.transcribe(fileURL: importURL)
            throw TestFailure("failed conversion must fail")
        } catch let issue as QuillUserIssueError {
            try expectEqual(issue.record.code, .audioPreparationFailed, "conversion failure code")
            try expectEqual(issue.record.context.providerHost, "provider.example", "conversion failure host")
        }
        try expectEqual(await recorder.uploads().count, 0, "failed conversion uploads nothing")
        try expectEqual(try leftoverFiles(in: temporaryRoot), [], "failed conversion leaves nothing")
    }

    private static func undecodableLargeImportKeepsSingleRequest() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let importURL = directory.appendingPathComponent("talk.webm")
        try Data(repeating: 0x1A, count: 40_000).write(to: importURL)
        let recorder = UploadRecorder(results: [.success("as before")])
        let progress = ChunkingProgressLog()
        let service = try makeService(
            ceiling: try importChunkCeiling(),
            recorder: recorder,
            checkpointStore: CountingCheckpointStore(),
            temporaryRoot: directory.appendingPathComponent("tmp", isDirectory: true),
            progress: { progress.record($0) }
        )

        let transcript = try await service.transcribe(fileURL: importURL)

        let uploads = await recorder.uploads()
        try expectEqual(uploads.count, 1, "undecodable import upload count")
        try expectContains(uploads[0].body, "filename=\"talk.webm\"", "undecodable import is sent as stored")
        try expectEqual(transcript.text, "as before", "undecodable import transcript")
        // One request, so no bar: only the spinner (#697).
        try expectEqual(progress.values(), [], "undecodable import reports no progress")
    }

    private static func cancellingImportConversionStopsBeforeUpload() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let importURL = try writeSyntheticCAF(in: directory, name: "long.caf")
        let temporaryRoot = directory.appendingPathComponent("tmp", isDirectory: true)
        let started = LockedCounter()
        let recorder = UploadRecorder(results: [])
        let service = try makeService(
            ceiling: try importChunkCeiling(),
            recorder: recorder,
            checkpointStore: CountingCheckpointStore(),
            temporaryRoot: temporaryRoot,
            audioPreparation: AudioImportConversionService(convert: { _ in
                started.increment()
                while true {
                    try Task.checkCancellation()
                    usleep(1_000)
                }
            })
        )

        let run = Task { try await service.transcribe(fileURL: importURL) }
        try await waitUntil("conversion starts") { started.value == 1 }
        run.cancel()
        do {
            _ = try await run.value
            throw TestFailure("cancelled conversion must not finish")
        } catch is CancellationError {}
        try expectEqual(await recorder.uploads().count, 0, "cancelled conversion uploads nothing")
        try expectEqual(try leftoverFiles(in: temporaryRoot), [], "cancelled conversion leaves nothing")
    }

    private static func waitUntil(
        _ label: String,
        _ condition: @Sendable () async -> Bool
    ) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw TestFailure("timed out waiting: \(label)")
    }

    private static func retryableHTTPFailureRetriesCurrentChunkOnly() async throws {
        let multipart = testMultipartLayout
        let ceiling = try multipart.encodedByteCount(
            audioDataByteCount: CanonicalPCM16WAV.headerByteCount + 4,
            fileName: CloudTranscriptionChunkPlanner.uploadFileName,
            contentType: "audio/wav"
        )
        let url = try writeCanonicalWAV(samples: [1, 1, 2, 2])
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = UploadRecorder(results: [
            .http(status: 503, body: #"{"error":{"message":"temporary"}}"#),
            .success("zero"),
            .success("one")
        ])
        let service = try makeService(
            ceiling: ceiling,
            recorder: recorder,
            checkpointStore: CountingCheckpointStore()
        )

        let transcript = try await service.transcribe(fileURL: url)
        try expectEqual(transcript.text, "zero one", "503 retry transcript")
        let markers = try await recorder.chunkMarkers()
        try expectEqual(markers, [1, 1, 2], "503 retries current chunk only")
    }

    private static func terminalProviderFailuresUseStableIssueRecords() async throws {
        for (status, providerCode, expectedCode, forbidden) in [
            (429, "insufficient_quota", QuillUserIssueCode.quotaExceeded, "secret quota detail"),
            (413, nil, QuillUserIssueCode.audioFileTooLarge, "secret payload detail")
        ] {
            let multipart = testMultipartLayout
            let ceiling = try multipart.encodedByteCount(
                audioDataByteCount: CanonicalPCM16WAV.headerByteCount + 4,
                fileName: CloudTranscriptionChunkPlanner.uploadFileName,
                contentType: "audio/wav"
            )
            let url = try writeCanonicalWAV(samples: [1, 1, 2, 2])
            defer { try? FileManager.default.removeItem(at: url) }
            let body = #"{"error":{"message":"\#(forbidden)","code":"\#(providerCode ?? "")","type":"\#(providerCode ?? "")"}}"#
            let recorder = UploadRecorder(results: [.http(status: status, body: body)])
            let service = try makeService(
                ceiling: ceiling,
                recorder: recorder,
                checkpointStore: CountingCheckpointStore()
            )
            do {
                _ = try await service.transcribe(fileURL: url)
                throw TestFailure("HTTP \(status) must fail")
            } catch let issue as QuillUserIssueError {
                try expectEqual(issue.record.code, expectedCode, "stable HTTP \(status) code")
                try expectEqual(issue.record.context.httpStatus, status, "safe HTTP status")
                try expectEqual(issue.record.context.providerHost, "provider.example", "safe provider host")
                try expectEqual(issue.record.context.modelID, "whisper-large-v3", "safe model ID")
                let payload = try issue.record.encodedStatus()
                guard !payload.contains(forbidden),
                      !issue.record.presentation().body.contains(forbidden) else {
                    throw TestFailure("user issue must not expose provider body")
                }
            }
            try expectEqual(await recorder.uploads().count, 1, "terminal HTTP \(status) upload count")
        }
    }

    private static func networkAndTimeoutFailuresUseStableIssueCodes() async throws {
        for (urlCode, expectedCode) in [
            (URLError.notConnectedToInternet, QuillUserIssueCode.networkUnavailable),
            (URLError.timedOut, QuillUserIssueCode.requestTimedOut)
        ] {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("mp3")
            try Data(repeating: 0x44, count: 128).write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            let recorder = UploadRecorder(results: [.urlError(urlCode)])
            let service = try makeService(
                ceiling: 10_000,
                recorder: recorder,
                checkpointStore: CountingCheckpointStore()
            )

            do {
                _ = try await service.transcribe(fileURL: url)
                throw TestFailure("URL error \(urlCode) must fail")
            } catch let issue as QuillUserIssueError {
                try expectEqual(issue.record.code, expectedCode, "stable URL error code")
                try expectEqual(issue.record.context.providerHost, "provider.example", "URL error provider host")
            }
        }
    }

    private static func invalidSuccessfulResponseUsesStableIssueRecord() async throws {
        let multipart = testMultipartLayout
        let ceiling = try multipart.encodedByteCount(
            audioDataByteCount: CanonicalPCM16WAV.headerByteCount + 4,
            fileName: CloudTranscriptionChunkPlanner.uploadFileName,
            contentType: "audio/wav"
        )
        let url = try writeCanonicalWAV(samples: [1, 1, 2, 2])
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = UploadRecorder(results: [.rawSuccess("")])
        let service = try makeService(
            ceiling: ceiling,
            recorder: recorder,
            checkpointStore: CountingCheckpointStore()
        )
        do {
            _ = try await service.transcribe(fileURL: url)
            throw TestFailure("invalid successful response must fail")
        } catch let issue as QuillUserIssueError {
            try expectEqual(issue.record.code, .invalidProviderResponse, "invalid response code")
        }
        try expectEqual(await recorder.uploads().count, 1, "invalid success must not retry")
    }

    private static func makeService(
        apiKey: String = "test-key",
        ceiling: UInt64,
        language: String? = "en",
        recorder: UploadRecorder,
        checkpointStore: any CloudTranscriptionCheckpointStore,
        temporaryRoot: URL? = nil,
        progress: @escaping @Sendable (CloudTranscriptionProgress) -> Void = { _ in },
        cloudExecutionContext: CloudTranscriptionExecutionContext? = nil,
        audioPreparation: AudioImportConversionService = AudioImportConversionService()
    ) throws -> TranscriptionService {
        try TranscriptionService(
            apiKey: apiKey,
            baseURL: "https://provider.example/v1",
            useLocalTranscription: false,
            transcriptionLanguage: .auto,
            transcriptionModel: "whisper-large-v3",
            language: language,
            cloudDependencies: CloudTranscriptionDependencies(
                encodedUploadCeilingBytes: ceiling,
                upload: { request, body in
                    try await recorder.upload(request: request, body: body)
                },
                checkpointStore: checkpointStore,
                progress: progress,
                temporaryRoot: temporaryRoot ?? FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true),
                sleep: { _ in },
                audioPreparation: audioPreparation
            ),
            cloudExecutionContext: cloudExecutionContext
        )
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-735-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A synthetic 48 kHz stereo float CAF (a tone with quiet gaps), so it is
    /// not canonical WAV and is larger than its 16 kHz mono conversion.
    private static func writeSyntheticCAF(
        in directory: URL,
        name: String,
        frameCount: AVAudioFrameCount = 14_400
    ) throws -> URL {
        let url = directory.appendingPathComponent(name)
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: 48_000,
            channels: 2
        ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw TestFailure("synthetic CAF format")
        }
        buffer.frameLength = frameCount
        for channel in 0..<2 {
            let samples = buffer.floatChannelData![channel]
            for frame in 0..<Int(frameCount) {
                let audible = (frame / 2_400) % 2 == 0
                samples[frame] = audible
                    ? Float(sin(Double(frame) * 2 * .pi * 440 / 48_000) * 0.5)
                    : 0
            }
        }
        do {
            let file = try AVAudioFile(
                forWriting: url,
                settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 2,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ],
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            try file.write(from: buffer)
        }
        return url
    }

    /// Fits about 1,700 converted frames per chunk: the 4,800-frame
    /// conversion of the synthetic CAF takes three or four chunks.
    private static func importChunkCeiling() throws -> UInt64 {
        try testMultipartLayout.encodedByteCount(
            audioDataByteCount: CanonicalPCM16WAV.headerByteCount + 3_400,
            fileName: CloudTranscriptionChunkPlanner.uploadFileName,
            contentType: "audio/wav"
        )
    }

    private static func singleUploadByteCount(for url: URL) throws -> UInt64 {
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        return try testMultipartLayout.encodedByteCount(
            audioDataByteCount: size?.uint64Value ?? 0,
            fileName: url.lastPathComponent,
            contentType: CloudTranscriptionUpload.contentType(forFileName: url.lastPathComponent)
        )
    }

    private static func sha256(of url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func leftoverFiles(in directory: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        var names: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                names.append(url.lastPathComponent)
            }
        }
        return names.sorted()
    }

    private static var testMultipartLayout: CloudTranscriptionMultipartLayout {
        CloudTranscriptionMultipartLayout(
            model: "whisper-large-v3",
            responseFormat: "verbose_json",
            language: "en",
            boundaryByteCount: 36
        )
    }

    private static func writeCanonicalWAV(samples: [Int16]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        var data = try CanonicalPCM16WAV.header(
            dataByteCount: UInt32(samples.count * 2)
        )
        for sample in samples {
            let bits = UInt16(bitPattern: sample)
            data.append(UInt8(bits & 0xff))
            data.append(UInt8((bits >> 8) & 0xff))
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    private static func expectContains(
        _ data: Data,
        _ expected: String,
        _ label: String
    ) throws {
        try expectContains(String(decoding: data, as: UTF8.self), expected, label)
    }

    private static func expectContains(
        _ value: String,
        _ expected: String,
        _ label: String
    ) throws {
        guard value.contains(expected) else {
            throw TestFailure("\(label): missing \(expected)")
        }
    }

    private static func expectEqual<T: Equatable>(
        _ actual: T,
        _ expected: T,
        _ label: String
    ) throws {
        guard actual == expected else {
            throw TestFailure("\(label): expected \(expected), got \(actual)")
        }
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private actor CountingCheckpointStore: CloudTranscriptionCheckpointStore {
    private var checkpoint: CloudTranscriptionCheckpoint?
    private var loads = 0
    private var prefixes: [Int] = []

    func loadCompatible(
        identity: CloudTranscriptionJobIdentity
    ) async throws -> CloudTranscriptionCheckpoint? {
        loads += 1
        guard checkpoint?.identity == identity else { return nil }
        return checkpoint
    }

    func save(_ checkpoint: CloudTranscriptionCheckpoint) async throws {
        self.checkpoint = checkpoint
        prefixes.append(checkpoint.completedRawTranscripts.count)
    }

    func recordFailure(
        category: CloudTranscriptionFailureCategory
    ) async throws {}

    func loadCount() -> Int { loads }
    func savedPrefixCounts() -> [Int] { prefixes }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [CloudTranscriptionProgress] = []

    func record(_ progress: CloudTranscriptionProgress) {
        lock.lock()
        recorded.append(progress)
        lock.unlock()
    }

    func events() -> [CloudTranscriptionProgress] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

private actor UploadRecorder {
    struct Upload: Sendable {
        let timeout: TimeInterval
        let authorization: String?
        let body: Data
    }

    enum ScriptedResult: Sendable {
        case success(String)
        case verboseJSON(text: String, language: String)
        case rawSuccess(String)
        case http(status: Int, body: String)
        case urlError(URLError.Code)
        /// Waits until cancelled, like a request cut off by a force-quit.
        case hang
    }

    private var results: [ScriptedResult]
    private var recorded: [Upload] = []
    private var activeUploads = 0
    private var maximumActiveUploads = 0

    init(results: [ScriptedResult]) {
        self.results = results
    }

    func upload(
        request: URLRequest,
        body: Data
    ) async throws -> (Data, URLResponse) {
        guard !results.isEmpty else {
            throw TestFailure("unexpected upload")
        }
        activeUploads += 1
        maximumActiveUploads = max(maximumActiveUploads, activeUploads)
        recorded.append(
            Upload(
                timeout: request.timeoutInterval,
                authorization: request.value(forHTTPHeaderField: "Authorization"),
                body: body
            )
        )
        defer { activeUploads -= 1 }
        let result = results.removeFirst()
        let status: Int
        let responseData: Data
        switch result {
        case .hang:
            try await Task.sleep(for: .seconds(3_600))
            throw CancellationError()
        case .urlError(let code):
            throw URLError(code)
        case .success(let text):
            status = 200
            responseData = try JSONSerialization.data(withJSONObject: ["text": text])
        case .verboseJSON(let text, let language):
            status = 200
            responseData = try JSONSerialization.data(
                withJSONObject: ["text": text, "language": language]
            )
        case .rawSuccess(let body):
            status = 200
            responseData = Data(body.utf8)
        case .http(let httpStatus, let body):
            status = httpStatus
            responseData = Data(body.utf8)
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (responseData, response)
    }

    func uploads() -> [Upload] { recorded }
    func maximumConcurrentUploads() -> Int { maximumActiveUploads }

    func chunkMarkers() throws -> [Int] {
        try recorded.map { upload in
            guard let riffRange = upload.body.range(of: Data("RIFF".utf8)) else {
                throw TestFailure("chunk body missing RIFF")
            }
            let sampleOffset = riffRange.lowerBound + Int(CanonicalPCM16WAV.headerByteCount)
            guard upload.body.count >= sampleOffset + 2 else {
                throw TestFailure("chunk body missing sample")
            }
            let bits = UInt16(upload.body[sampleOffset])
                | (UInt16(upload.body[sampleOffset + 1]) << 8)
            return Int(Int16(bitPattern: bits))
        }
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

/// Progress events, in order, from any thread.
final class ChunkingProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [CloudTranscriptionProgress] = []

    func record(_ progress: CloudTranscriptionProgress) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(progress)
    }

    func values() -> [CloudTranscriptionProgress] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }
}
