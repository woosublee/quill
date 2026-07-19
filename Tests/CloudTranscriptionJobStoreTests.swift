import Foundation

@main
struct CloudTranscriptionJobStoreTests {
    static func main() async {
        do {
            try roundTripsSchemaVersionOne()
            try rejectsUnsupportedSchemaVersion()
            try rejectsFileNameHistoryIDMismatch()
            try rejectsUnsafeSourceBasenames()
            try rejectsInvalidSourceLayout()
            try rejectsSourcePlanMismatch()
            try rejectsNonContiguousOrDuplicateCompletedChunks()
            try rejectsIncorrectFirstIncompleteIndex()
            try rejectsAssembledRecordBeforeAllChunksComplete()
            try rejectsFutureChunkAlgorithmVersion()
            try encodedRecordExcludesCredentialsAndSensitiveArtifacts()
            try atomicRoundtripUsesSiblingTemporaryFileAndRestrictedPermissions()
            try writeFailuresPreserveAReadableGeneration()
            try staleSessionsCannotMutateAReplacementJob()
            try await checkpointAdapterPersistsContiguousProgress()
            try await staleCheckpointAdapterCannotResurrectDeletedJob()
            try reconciliationClassifiesCompatibleAndInvalidRecords()
            try removesStaleTemporaryArtifacts()
            print("CloudTranscriptionJobStoreTests passed")
        } catch {
            fputs("CloudTranscriptionJobStoreTests failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func roundTripsSchemaVersionOne() throws {
        let original = makeRecord(
            phase: .transcribing,
            completedChunks: [
                CloudTranscriptionCompletedChunk(
                    index: 0,
                    normalizedRawText: "first chunk"
                )
            ],
            firstIncompleteChunkIndex: 1
        )
        try original.validate(fileNameID: original.historyID)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(
            CloudTranscriptionJobRecord.self,
            from: data
        )

        try expectEqual(decoded, original, "schema v1 roundtrip")
        try expectEqual(
            decoded.schemaVersion,
            CloudTranscriptionJobRecord.currentSchemaVersion,
            "current schema version"
        )
    }

    private static func rejectsUnsupportedSchemaVersion() throws {
        let record = makeRecord(schemaVersion: 2)
        try expectValidationError(
            .unsupportedSchemaVersion(2),
            record: record,
            fileNameID: record.historyID,
            label: "future schema"
        )
    }

    private static func rejectsFileNameHistoryIDMismatch() throws {
        let record = makeRecord()
        try expectValidationError(
            .historyIDMismatch,
            record: record,
            fileNameID: UUID(),
            label: "filename/history ID mismatch"
        )
    }

    private static func rejectsUnsafeSourceBasenames() throws {
        for fileName in [
            "../recording.wav",
            "/tmp/recording.wav",
            "folder/recording.wav",
            "folder\\recording.wav",
            ".",
            "..",
            ""
        ] {
            let record = makeRecord(audioFileName: fileName)
            try expectValidationError(
                .unsafeAudioFileName,
                record: record,
                fileNameID: record.historyID,
                label: "unsafe basename \(fileName)"
            )
        }
    }

    private static func rejectsInvalidSourceLayout() throws {
        let record = makeRecord(
            physicalByteCount: CanonicalPCM16WAV.headerByteCount + 10
        )
        try expectValidationError(
            .invalidSourceIdentity,
            record: record,
            fileNameID: record.historyID,
            label: "physical source size"
        )
    }

    private static func rejectsSourcePlanMismatch() throws {
        let record = makeRecord(sourceFrameCount: 7)
        try expectValidationError(
            .sourcePlanMismatch,
            record: record,
            fileNameID: record.historyID,
            label: "source frame count and plan"
        )
    }

    private static func rejectsNonContiguousOrDuplicateCompletedChunks() throws {
        let nonContiguous = makeRecord(
            completedChunks: [
                CloudTranscriptionCompletedChunk(
                    index: 0,
                    normalizedRawText: "zero"
                ),
                CloudTranscriptionCompletedChunk(
                    index: 2,
                    normalizedRawText: "two"
                )
            ],
            firstIncompleteChunkIndex: 2
        )
        try expectValidationError(
            .invalidCompletedChunkPrefix,
            record: nonContiguous,
            fileNameID: nonContiguous.historyID,
            label: "non-contiguous completed prefix"
        )

        let duplicate = makeRecord(
            completedChunks: [
                CloudTranscriptionCompletedChunk(
                    index: 0,
                    normalizedRawText: "zero"
                ),
                CloudTranscriptionCompletedChunk(
                    index: 0,
                    normalizedRawText: "duplicate"
                )
            ],
            firstIncompleteChunkIndex: 2
        )
        try expectValidationError(
            .invalidCompletedChunkPrefix,
            record: duplicate,
            fileNameID: duplicate.historyID,
            label: "duplicate completed index"
        )
    }

    private static func rejectsIncorrectFirstIncompleteIndex() throws {
        let record = makeRecord(
            completedChunks: [
                CloudTranscriptionCompletedChunk(
                    index: 0,
                    normalizedRawText: "zero"
                )
            ],
            firstIncompleteChunkIndex: 0
        )
        try expectValidationError(
            .firstIncompleteChunkIndexMismatch,
            record: record,
            fileNameID: record.historyID,
            label: "first incomplete index"
        )
    }

    private static func rejectsAssembledRecordBeforeAllChunksComplete() throws {
        let record = makeRecord(
            phase: .assembled,
            completedChunks: [
                CloudTranscriptionCompletedChunk(
                    index: 0,
                    normalizedRawText: "zero"
                )
            ],
            firstIncompleteChunkIndex: 1
        )
        try expectValidationError(
            .assembledBeforeComplete,
            record: record,
            fileNameID: record.historyID,
            label: "assembled incomplete record"
        )
    }

    private static func rejectsFutureChunkAlgorithmVersion() throws {
        let record = makeRecord(
            planAlgorithmVersion:
                CloudTranscriptionChunkPlan.currentAlgorithmVersion + 1
        )
        try expectValidationError(
            .invalidPlan,
            record: record,
            fileNameID: record.historyID,
            label: "future chunk algorithm"
        )
    }

    private static func encodedRecordExcludesCredentialsAndSensitiveArtifacts() throws {
        let fakeAPIKey = "sk-test-secret-never-persist"
        let fakeAuthorization = "Bearer secret-authorization-value"
        let fakeSourcePath = "/Users/example/Library/Application Support/Quill/audio/recording.wav"
        let fakeTemporaryPath = "/private/tmp/quill-cloud/chunk.wav"
        let fakeProviderBody = "provider raw response must not persist"
        let record = makeRecord(
            lastFailure: CloudTranscriptionStoredFailure(
                category: .authentication,
                httpStatus: 401,
                retryAfterSeconds: nil
            )
        )

        let data = try JSONEncoder().encode(record)
        let object = try JSONSerialization.jsonObject(with: data)
        var keys: [String] = []
        var values: [String] = []
        collectJSON(object, keys: &keys, values: &values)

        let normalizedKeys = Set(keys.map { $0.lowercased() })
        for forbiddenKey in [
            "apikey",
            "api_key",
            "oauth",
            "authorization",
            "rawproviderresponse",
            "absolutepath",
            "temporarypath",
            "chunkwav",
            "partialpostprocessedtranscript"
        ] {
            try expect(
                !normalizedKeys.contains(forbiddenKey),
                "forbidden JSON key \(forbiddenKey)"
            )
        }

        let encodedStrings = values.joined(separator: "\n")
        for forbiddenValue in [
            fakeAPIKey,
            fakeAuthorization,
            fakeSourcePath,
            fakeTemporaryPath,
            fakeProviderBody
        ] {
            try expect(
                !encodedStrings.contains(forbiddenValue),
                "forbidden JSON value \(forbiddenValue)"
            )
        }
        try expect(
            values.contains("recording.wav"),
            "source basename remains encoded"
        )
    }

    private static func atomicRoundtripUsesSiblingTemporaryFileAndRestrictedPermissions() throws {
        let fixture = try makeStoreFixture()
        defer { fixture.cleanup() }
        let store = CloudTranscriptionJobStore(
            jobsDirectory: fixture.jobsDirectory,
            temporaryRoot: fixture.temporaryRoot
        )
        let record = makeRecord()
        let session = store.beginSession(historyID: record.historyID)

        try store.create(record, session: session)

        let loaded = try store.load(historyID: record.historyID)
        try expectEqual(loaded, record, "atomic roundtrip")
        let recordURL = fixture.jobsDirectory.appendingPathComponent(
            "\(record.historyID.uuidString).json"
        )
        let attributes = try FileManager.default.attributesOfItem(
            atPath: recordURL.path
        )
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        try expectEqual(permissions, 0o600, "sidecar permissions")
        let siblingNames = try FileManager.default.contentsOfDirectory(
            atPath: fixture.jobsDirectory.path
        )
        try expectEqual(
            siblingNames,
            [recordURL.lastPathComponent],
            "no sibling temporary file remains"
        )
    }

    private static func writeFailuresPreserveAReadableGeneration() throws {
        for stage in TestAtomicWriteStage.allCases {
            let fixture = try makeStoreFixture()
            defer { fixture.cleanup() }
            let originalStore = CloudTranscriptionJobStore(
                jobsDirectory: fixture.jobsDirectory,
                temporaryRoot: fixture.temporaryRoot
            )
            let original = makeRecord()
            let originalSession = originalStore.beginSession(
                historyID: original.historyID
            )
            try originalStore.create(original, session: originalSession)

            let replacementDate = Date(timeIntervalSince1970: 3_000)
            var replacement = original
            replacement.updatedAt = replacementDate
            replacement.phase = .transcribing
            let failingStore = CloudTranscriptionJobStore(
                jobsDirectory: fixture.jobsDirectory,
                temporaryRoot: fixture.temporaryRoot,
                now: { replacementDate },
                atomicWriteOperations: failingOperations(at: stage)
            )
            let failingSession = failingStore.beginSession(
                historyID: original.historyID
            )
            do {
                try failingStore.update(replacement, session: failingSession)
                throw TestFailure("\(stage): injected write failure must throw")
            } catch TestAtomicWriteError.injected {
                // expected
            }

            let loaded = try originalStore.load(historyID: original.historyID)
            try expect(
                loaded == original || loaded == replacement,
                "\(stage): one complete generation remains readable"
            )
            if let loaded {
                try loaded.validate(fileNameID: original.historyID)
            }
        }
    }

    private static func staleSessionsCannotMutateAReplacementJob() throws {
        let fixture = try makeStoreFixture()
        defer { fixture.cleanup() }
        let record = makeRecord()
        let replacementDate = Date(timeIntervalSince1970: 3_000)
        let store = CloudTranscriptionJobStore(
            jobsDirectory: fixture.jobsDirectory,
            temporaryRoot: fixture.temporaryRoot,
            now: { replacementDate }
        )
        let sessionA = store.beginSession(historyID: record.historyID)
        try store.create(record, session: sessionA)
        store.invalidateSession(historyID: record.historyID)
        let sessionB = store.beginSession(historyID: record.historyID)

        var replacement = record
        replacement.updatedAt = replacementDate
        replacement.phase = .transcribing
        try store.update(replacement, session: sessionB)

        for operation in ["update", "delete"] {
            do {
                if operation == "update" {
                    try store.update(record, session: sessionA)
                } else {
                    try store.delete(
                        historyID: record.historyID,
                        session: sessionA
                    )
                }
                throw TestFailure("stale \(operation) must fail")
            } catch CloudTranscriptionJobStoreError.staleSession {
                // expected
            }
        }
        try expectEqual(
            try store.load(historyID: record.historyID),
            replacement,
            "replacement generation survives stale callbacks"
        )
    }

    private static func checkpointAdapterPersistsContiguousProgress() async throws {
        let fixture = try makeStoreFixture()
        defer { fixture.cleanup() }
        let store = CloudTranscriptionJobStore(
            jobsDirectory: fixture.jobsDirectory,
            temporaryRoot: fixture.temporaryRoot
        )
        let record = makeRecord(phase: .transcribing)
        let session = store.beginSession(historyID: record.historyID)
        try store.create(record, session: session)
        let adapter = store.checkpointStore(session: session)
        let checkpoint = CloudTranscriptionCheckpoint(
            identity: record.identity,
            completedRawTranscripts: [" first   chunk "]
        )

        try await adapter.save(checkpoint)

        let loadedCheckpoint = try await adapter.loadCompatible(
            identity: record.identity
        )
        try expectEqual(
            loadedCheckpoint?.completedRawTranscripts,
            ["first chunk"],
            "checkpoint adapter normalizes and reloads prefix"
        )
        let loadedRecord = try store.load(historyID: record.historyID)
        try expectEqual(
            loadedRecord?.completedChunks,
            [CloudTranscriptionCompletedChunk(
                index: 0,
                normalizedRawText: "first chunk"
            )],
            "checkpoint sidecar prefix"
        )
        try expectEqual(
            loadedRecord?.firstIncompleteChunkIndex,
            1,
            "checkpoint first incomplete index"
        )
    }

    private static func staleCheckpointAdapterCannotResurrectDeletedJob() async throws {
        let fixture = try makeStoreFixture()
        defer { fixture.cleanup() }
        let store = CloudTranscriptionJobStore(
            jobsDirectory: fixture.jobsDirectory,
            temporaryRoot: fixture.temporaryRoot
        )
        let record = makeRecord(phase: .transcribing)
        let session = store.beginSession(historyID: record.historyID)
        try store.create(record, session: session)
        let adapter = store.checkpointStore(session: session)
        try store.delete(historyID: record.historyID, session: session)

        do {
            try await adapter.save(CloudTranscriptionCheckpoint(
                identity: record.identity,
                completedRawTranscripts: ["late chunk"]
            ))
            throw TestFailure("late checkpoint must not recreate sidecar")
        } catch CloudTranscriptionJobStoreError.staleSession {
            // expected
        }
        try expectEqual(
            try store.load(historyID: record.historyID),
            nil,
            "deleted sidecar remains deleted"
        )
    }

    private static func reconciliationClassifiesCompatibleAndInvalidRecords() throws {
        let fixture = try makeStoreFixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(
            at: fixture.audioRoot,
            withIntermediateDirectories: true
        )
        let store = CloudTranscriptionJobStore(
            jobsDirectory: fixture.jobsDirectory,
            temporaryRoot: fixture.temporaryRoot
        )

        let resumableID = UUID()
        let resumableURL = fixture.audioRoot.appendingPathComponent("resumable.wav")
        try writeCanonicalFixture(to: resumableURL)
        let resumable = try makeRecordForAudio(
            historyID: resumableID,
            fileURL: resumableURL,
            phase: .interrupted
        )
        try store.create(
            resumable,
            session: store.beginSession(historyID: resumableID)
        )

        let failedID = UUID()
        let failedURL = fixture.audioRoot.appendingPathComponent("failed.wav")
        try writeCanonicalFixture(to: failedURL)
        let failed = try makeRecordForAudio(
            historyID: failedID,
            fileURL: failedURL,
            phase: .failed
        )
        try store.create(
            failed,
            session: store.beginSession(historyID: failedID)
        )

        let orphanID = UUID()
        let orphanURL = fixture.audioRoot.appendingPathComponent("orphan.wav")
        try writeCanonicalFixture(to: orphanURL)
        let orphan = try makeRecordForAudio(
            historyID: orphanID,
            fileURL: orphanURL,
            phase: .transcribing
        )
        try store.create(
            orphan,
            session: store.beginSession(historyID: orphanID)
        )

        let missingAudioID = UUID()
        let missingAudioURL = fixture.audioRoot.appendingPathComponent(
            "missing.wav"
        )
        try writeCanonicalFixture(to: missingAudioURL)
        let missingAudio = try makeRecordForAudio(
            historyID: missingAudioID,
            fileURL: missingAudioURL,
            phase: .transcribing
        )
        try store.create(
            missingAudio,
            session: store.beginSession(historyID: missingAudioID)
        )
        try FileManager.default.removeItem(at: missingAudioURL)

        let changedSourceID = UUID()
        let changedSourceURL = fixture.audioRoot.appendingPathComponent(
            "changed.wav"
        )
        try writeCanonicalFixture(to: changedSourceURL)
        let changedSource = try makeRecordForAudio(
            historyID: changedSourceID,
            fileURL: changedSourceURL,
            phase: .transcribing
        )
        try store.create(
            changedSource,
            session: store.beginSession(historyID: changedSourceID)
        )
        var changedData = try Data(contentsOf: changedSourceURL)
        changedData[changedData.startIndex + Int(CanonicalPCM16WAV.headerByteCount)] ^= 0xff
        try changedData.write(to: changedSourceURL, options: .atomic)

        let corruptID = UUID()
        try Data("not json".utf8).write(
            to: fixture.jobsDirectory.appendingPathComponent(
                "\(corruptID.uuidString).json"
            )
        )

        let reconciliation = store.reconcile(
            history: [
                makeHistory(id: resumableID, audioFileName: "resumable.wav"),
                makeHistory(id: failedID, audioFileName: "failed.wav"),
                makeHistory(id: missingAudioID, audioFileName: "missing.wav"),
                makeHistory(id: changedSourceID, audioFileName: "changed.wav")
            ],
            audioRoot: fixture.audioRoot
        )

        try expectEqual(
            reconciliation.resumable.map(\.historyID),
            [resumableID],
            "compatible interrupted job"
        )
        try expectEqual(
            reconciliation.waitingForRetry.map(\.historyID),
            [failedID],
            "terminal job waits for explicit retry"
        )
        try expectEqual(
            Set(reconciliation.invalid),
            Set([orphanID, missingAudioID, changedSourceID, corruptID]),
            "orphan, missing, changed, and corrupt sidecars"
        )
    }

    private static func removesStaleTemporaryArtifacts() throws {
        let fixture = try makeStoreFixture()
        defer { fixture.cleanup() }
        let staleDirectory = fixture.temporaryRoot.appendingPathComponent(
            "stale-attempt",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: staleDirectory,
            withIntermediateDirectories: true
        )
        try Data([1, 2, 3]).write(
            to: staleDirectory.appendingPathComponent("chunk.wav")
        )
        let store = CloudTranscriptionJobStore(
            jobsDirectory: fixture.jobsDirectory,
            temporaryRoot: fixture.temporaryRoot
        )

        try store.removeStaleTemporaryArtifacts()

        let contents = try FileManager.default.contentsOfDirectory(
            atPath: fixture.temporaryRoot.path
        )
        try expectEqual(contents, [], "stale temporary artifacts removed")
    }

    private static func makeRecord(
        schemaVersion: Int = 1,
        phase: CloudTranscriptionJobPhase = .prepared,
        audioFileName: String = "recording.wav",
        physicalByteCount: UInt64? = nil,
        sourceFrameCount: UInt64 = 6,
        planAlgorithmVersion: Int = CloudTranscriptionChunkPlan.currentAlgorithmVersion,
        completedChunks: [CloudTranscriptionCompletedChunk] = [],
        firstIncompleteChunkIndex: Int = 0,
        lastFailure: CloudTranscriptionStoredFailure? = nil
    ) -> CloudTranscriptionJobRecord {
        let historyID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let dataByteCount = sourceFrameCount
            * UInt64(CanonicalPCM16WAV.bytesPerFrame)
        let source = CloudTranscriptionSourceIdentity(
            audioFileName: audioFileName,
            physicalByteCount: physicalByteCount
                ?? CanonicalPCM16WAV.headerByteCount + dataByteCount,
            sha256: String(repeating: "a", count: 64),
            dataByteCount: dataByteCount,
            frameCount: sourceFrameCount
        )
        let chunks = [
            CloudTranscriptionChunk(
                index: 0,
                startFrame: 0,
                endFrame: 3,
                estimatedEncodedByteCount: 500
            ),
            CloudTranscriptionChunk(
                index: 1,
                startFrame: 3,
                endFrame: 6,
                estimatedEncodedByteCount: 500
            )
        ]
        let plan = CloudTranscriptionChunkPlan(
            algorithmVersion: planAlgorithmVersion,
            encodedUploadCeilingBytes: 1_000,
            sourceFrameCount: 6,
            chunks: chunks,
            planID: "plan-v1"
        )
        let identity = CloudTranscriptionJobIdentity(
            providerID: String(repeating: "b", count: 64),
            model: "whisper-large-v3",
            language: "en",
            responseFormat: "verbose_json",
            source: source,
            planID: plan.planID
        )
        return CloudTranscriptionJobRecord(
            schemaVersion: schemaVersion,
            historyID: historyID,
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 2_000),
            phase: phase,
            identity: identity,
            plan: plan,
            completedChunks: completedChunks,
            firstIncompleteChunkIndex: firstIncompleteChunkIndex,
            lastFailure: lastFailure,
            completionPolicy: CloudTranscriptionCompletionPolicy(
                postProcessingEnabled: true,
                preserveExactWording: false,
                outputLanguage: "en",
                pressEnterCommandEnabled: false
            )
        )
    }

    private static func makeStoreFixture() throws -> StoreFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return StoreFixture(
            root: root,
            jobsDirectory: root.appendingPathComponent("jobs", isDirectory: true),
            temporaryRoot: root.appendingPathComponent("temporary", isDirectory: true),
            audioRoot: root.appendingPathComponent("audio", isDirectory: true)
        )
    }

    private static func failingOperations(
        at stage: TestAtomicWriteStage
    ) -> CloudTranscriptionAtomicWriteOperations {
        let live = CloudTranscriptionAtomicWriteOperations.live
        return CloudTranscriptionAtomicWriteOperations(
            openTemporary: { url in
                if stage == .open { throw TestAtomicWriteError.injected }
                return try live.openTemporary(url)
            },
            writeAll: { data, descriptor in
                if stage == .write { throw TestAtomicWriteError.injected }
                try live.writeAll(data, descriptor)
            },
            syncFile: { descriptor in
                if stage == .fileSync { throw TestAtomicWriteError.injected }
                try live.syncFile(descriptor)
            },
            closeFile: { descriptor in
                if stage == .close { throw TestAtomicWriteError.injected }
                try live.closeFile(descriptor)
            },
            replace: { temporaryURL, targetURL in
                if stage == .replace { throw TestAtomicWriteError.injected }
                try live.replace(temporaryURL, targetURL)
            },
            syncDirectory: { directoryURL in
                if stage == .directorySync {
                    throw TestAtomicWriteError.injected
                }
                try live.syncDirectory(directoryURL)
            }
        )
    }

    private static func writeCanonicalFixture(to url: URL) throws {
        var data = CanonicalPCM16WAV.header(dataByteCount: 12)
        for sample in [Int16(1), 2, 3, 4, 5, 6] {
            let bits = UInt16(bitPattern: sample)
            data.append(UInt8(bits & 0xff))
            data.append(UInt8((bits >> 8) & 0xff))
        }
        try data.write(to: url, options: .atomic)
    }

    private static func makeRecordForAudio(
        historyID: UUID,
        fileURL: URL,
        phase: CloudTranscriptionJobPhase
    ) throws -> CloudTranscriptionJobRecord {
        let layout = try CanonicalPCM16WAV.validateFile(at: fileURL)
        let source = try CloudTranscriptionSourceIdentityBuilder.make(
            fileURL: fileURL,
            layout: layout,
            readBufferByteCount: 3
        )
        let chunks = [
            CloudTranscriptionChunk(
                index: 0,
                startFrame: 0,
                endFrame: 3,
                estimatedEncodedByteCount: 500
            ),
            CloudTranscriptionChunk(
                index: 1,
                startFrame: 3,
                endFrame: 6,
                estimatedEncodedByteCount: 500
            )
        ]
        let plan = CloudTranscriptionChunkPlan(
            algorithmVersion: CloudTranscriptionChunkPlan.currentAlgorithmVersion,
            encodedUploadCeilingBytes: 1_000,
            sourceFrameCount: layout.frameCount,
            chunks: chunks,
            planID: "plan-v1"
        )
        return CloudTranscriptionJobRecord(
            schemaVersion: CloudTranscriptionJobRecord.currentSchemaVersion,
            historyID: historyID,
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 2_000),
            phase: phase,
            identity: CloudTranscriptionJobIdentity(
                providerID: String(repeating: "b", count: 64),
                model: "whisper-large-v3",
                language: "en",
                responseFormat: "verbose_json",
                source: source,
                planID: plan.planID
            ),
            plan: plan,
            completedChunks: [],
            firstIncompleteChunkIndex: 0,
            lastFailure: phase == .failed
                ? CloudTranscriptionStoredFailure(
                    category: .authentication,
                    httpStatus: 401,
                    retryAfterSeconds: nil
                )
                : nil,
            completionPolicy: CloudTranscriptionCompletionPolicy(
                postProcessingEnabled: true,
                preserveExactWording: false,
                outputLanguage: "en",
                pressEnterCommandEnabled: false
            )
        )
    }

    private static func makeHistory(
        id: UUID,
        audioFileName: String
    ) -> PipelineHistoryItem {
        PipelineHistoryItem(
            id: id,
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
            audioFileName: audioFileName
        )
    }

    private static func expectValidationError(
        _ expected: CloudTranscriptionJobValidationError,
        record: CloudTranscriptionJobRecord,
        fileNameID: UUID,
        label: String
    ) throws {
        do {
            try record.validate(fileNameID: fileNameID)
            throw TestFailure("\(label): expected \(expected)")
        } catch let error as CloudTranscriptionJobValidationError {
            try expectEqual(error, expected, label)
        }
    }

    private static func collectJSON(
        _ value: Any,
        keys: inout [String],
        values: inout [String]
    ) {
        if let dictionary = value as? [String: Any] {
            for (key, child) in dictionary {
                keys.append(key)
                collectJSON(child, keys: &keys, values: &values)
            }
        } else if let array = value as? [Any] {
            for child in array {
                collectJSON(child, keys: &keys, values: &values)
            }
        } else if let string = value as? String {
            values.append(string)
        }
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ label: String
    ) throws {
        guard condition() else { throw TestFailure(label) }
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

private struct StoreFixture {
    let root: URL
    let jobsDirectory: URL
    let temporaryRoot: URL
    let audioRoot: URL

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private enum TestAtomicWriteStage: String, CaseIterable {
    case open
    case write
    case fileSync
    case close
    case replace
    case directorySync
}

private enum TestAtomicWriteError: Error {
    case injected
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
