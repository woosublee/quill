import Foundation

@main
struct CloudTranscriptionJobStoreTests {
    static func main() {
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

private struct TestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
