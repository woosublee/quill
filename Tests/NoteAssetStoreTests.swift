import Foundation
import QuillAudioFormatCore

#if !QUILL_GROUPED_TEST_RUNNER
@main
#endif
struct NoteAssetStoreTests {
    static func main() async throws {
        try testSaveAndLoadTranscriptRoundTrips()
        try testSaveTranscriptPrefersPostProcessedText()
        try testLoadTranscriptThrowsForMissingFile()
        try testDeleteTranscriptIsIdempotentForMissingFile()
        try testSaveAudioCopiesFileAndPreservesExtension()
        try testSaveAudioRefreshesModificationDate()
        try testAdoptStoppedAudioReusesCanonicalWAVInAudioDirectory()
        try testAdoptStoppedAudioCopiesExternalFile()
        try testAdoptStoppedAudioCopiesInvalidWAVAlreadyInAudioDirectory()
        try testSaveAudioThrowsWhenSourceFileIsMissing()
        try await testSaveSecurityScopedAudioThrowsWhenSourceFileIsMissing()
        try testDeleteAudioIsIdempotentForMissingFile()
        try testDeleteAssetsRemovesBothFiles()
        try testDeleteTranscriptPropagatesNonMissingFileErrors()
        try testDeleteAudioPropagatesNonMissingFileErrors()
        try testDeleteAssetsStillDeletesTranscriptWhenAudioDeleteFails()
        try testDeleteRejectsParentDirectoryTraversal()
        try testLoadTranscriptRejectsParentDirectoryTraversal()
        try testStoredAudioURLRejectsParentDirectoryTraversal()
        try testSweepOrphansPreservesReferencedAndProtectedAssets()
        try testSweepOrphansPreservesRecentAssets()
        try testSweepOrphansDeletesOldUnreferencedAssets()
        try testSweepOrphansRequiresTrustedReferences()
        try testStoredAudioURLResolvesFromItem()
        try testStoredAudioURLIsNilWithoutAudioFileName()
        try testPrepareDirectoriesCreatesAudioAndTranscriptDirectories()
        try testTwoStoresWithIndependentLayoutsDoNotShareFiles()
        try testOneStoreCannotDeleteAnotherStoresTranscript()
        try testSaveTranscriptThrowsWhenDirectoryIsUnavailable()
        try testSaveAudioThrowsWhenDirectoryIsUnavailable()
        print("NoteAssetStoreTests passed")
    }

    private static func testSaveAndLoadTranscriptRoundTrips() throws {
        try withTemporaryStore { store in
            let fileName = try store.saveTranscript(
                rawTranscript: "raw",
                postProcessedTranscript: "processed"
            )
            let loaded = try store.loadTranscript(fileName: fileName)
            try expect(loaded == "processed", "loaded transcript matches the saved content")
        }
    }

    private static func testSaveTranscriptPrefersPostProcessedText() throws {
        try withTemporaryStore { store in
            let fileName = try store.saveTranscript(
                rawTranscript: "raw only",
                postProcessedTranscript: ""
            )
            let loaded = try store.loadTranscript(fileName: fileName)
            try expect(
                loaded == "raw only",
                "an empty post-processed transcript falls back to the raw transcript"
            )
        }
    }

    private static func testLoadTranscriptThrowsForMissingFile() throws {
        try withTemporaryStore { store in
            do {
                _ = try store.loadTranscript(fileName: "missing-\(UUID().uuidString).txt")
                throw TestFailure("expected loadTranscript to throw for a missing file")
            } catch is NoteAssetStoreError {
                // expected
            }
        }
    }

    private static func testDeleteTranscriptIsIdempotentForMissingFile() throws {
        try withTemporaryStore { store in
            try store.deleteTranscript(fileName: "missing-\(UUID().uuidString).txt")
        }
    }

    private static func testSaveAudioCopiesFileAndPreservesExtension() throws {
        try withTemporaryStore { store in
            let sourceURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("note-asset-store-source-\(UUID().uuidString).m4a")
            let contents = Data("audio contents".utf8)
            try contents.write(to: sourceURL)
            defer { try? FileManager.default.removeItem(at: sourceURL) }

            let saved = try store.saveAudio(from: sourceURL)
            try expect(saved.fileName.hasSuffix(".m4a"), "saved audio keeps the source extension")
            let copied = try Data(contentsOf: saved.fileURL)
            try expect(copied == contents, "saved audio contents match the source file")
        }
    }

    private static func testSaveAudioRefreshesModificationDate() throws {
        try withTemporaryStore { store in
            let sourceURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "note-asset-store-old-source-\(UUID().uuidString).m4a"
                )
            try Data("audio contents".utf8).write(to: sourceURL)
            try setModificationDate(
                of: sourceURL,
                to: Date(timeIntervalSince1970: 0)
            )
            defer { try? FileManager.default.removeItem(at: sourceURL) }

            let saved = try store.saveAudio(from: sourceURL)
            let modificationDate = try saved.fileURL.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate

            try expect(
                modificationDate.map {
                    Date().timeIntervalSince($0) < 10
                } == true,
                "saved audio receives a fresh modification date"
            )
        }
    }

    private static func testAdoptStoppedAudioReusesCanonicalWAVInAudioDirectory() throws {
        try withTemporaryStore { store in
            let fileURL = store.storageLayout.audioDirectory
                .appendingPathComponent("promoted.wav")
            let originalData = try canonicalWAVData(samples: [12, 34])
            try originalData.write(to: fileURL)
            let before = try audioFileNames(in: store)

            let saved = try store.adoptOrSaveStoppedAudio(from: fileURL)

            try expect(
                saved.fileURL == fileURL.standardizedFileURL,
                "canonical stopped audio is reused"
            )
            try expect(
                saved.fileName == fileURL.lastPathComponent,
                "canonical stopped audio keeps its name"
            )
            let savedData = try Data(contentsOf: saved.fileURL)
            try expect(
                savedData == originalData,
                "reused audio remains unchanged"
            )
            let after = try audioFileNames(in: store)
            try expect(
                after == before,
                "reusing canonical audio does not create a second file"
            )
        }
    }

    private static func testAdoptStoppedAudioCopiesExternalFile() throws {
        try withTemporaryStore { store in
            let sourceURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("note-asset-store-external-\(UUID().uuidString).wav")
            let contents = try canonicalWAVData(samples: [56, 78])
            try contents.write(to: sourceURL)
            defer { try? FileManager.default.removeItem(at: sourceURL) }

            let saved = try store.adoptOrSaveStoppedAudio(from: sourceURL)

            try expect(
                saved.fileURL != sourceURL.standardizedFileURL,
                "external stopped audio is copied"
            )
            try expect(
                saved.fileURL.deletingLastPathComponent()
                    == store.storageLayout.audioDirectory.standardizedFileURL,
                "external stopped audio is saved under the store audio directory"
            )
            let savedData = try Data(contentsOf: saved.fileURL)
            try expect(
                savedData == contents,
                "copied stopped audio preserves contents"
            )
        }
    }

    private static func testAdoptStoppedAudioCopiesInvalidWAVAlreadyInAudioDirectory() throws {
        try withTemporaryStore { store in
            let sourceURL = store.storageLayout.audioDirectory
                .appendingPathComponent("invalid.wav")
            let contents = Data("not a canonical wav".utf8)
            try contents.write(to: sourceURL)

            let saved = try store.adoptOrSaveStoppedAudio(from: sourceURL)

            try expect(
                saved.fileURL != sourceURL.standardizedFileURL,
                "invalid in-place WAV is copied instead of adopted"
            )
            let savedData = try Data(contentsOf: saved.fileURL)
            try expect(
                savedData == contents,
                "copied invalid WAV preserves contents"
            )
        }
    }

    private static func testSaveAudioThrowsWhenSourceFileIsMissing() throws {
        try withTemporaryStore { store in
            let missingURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("note-asset-store-missing-\(UUID().uuidString).wav")
            do {
                _ = try store.saveAudio(from: missingURL)
                throw TestFailure("expected saveAudio to throw for a missing source file")
            } catch is NoteAssetStoreError {
                // expected
            }
        }
    }

    private static func testSaveSecurityScopedAudioThrowsWhenSourceFileIsMissing() async throws {
        try await withTemporaryStoreAsync { store in
            let missingURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("note-asset-store-missing-scoped-\(UUID().uuidString).wav")
            do {
                _ = try await store.saveSecurityScopedAudio(from: missingURL)
                throw TestFailure(
                    "expected saveSecurityScopedAudio to throw for a missing source file"
                )
            } catch is NoteAssetStoreError {
                // expected
            }
        }
    }

    private static func testDeleteAudioIsIdempotentForMissingFile() throws {
        try withTemporaryStore { store in
            try store.deleteAudio(fileName: "missing-\(UUID().uuidString).wav")
        }
    }

    private static func testDeleteAssetsRemovesBothFiles() throws {
        try withTemporaryStore { store in
            let transcriptFileName = try store.saveTranscript(
                rawTranscript: "to delete",
                postProcessedTranscript: ""
            )
            let sourceURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("note-asset-store-to-delete-\(UUID().uuidString).wav")
            try Data("fixture".utf8).write(to: sourceURL)
            defer { try? FileManager.default.removeItem(at: sourceURL) }
            let savedAudio = try store.saveAudio(from: sourceURL)

            try store.deleteAssets(
                audioFileName: savedAudio.fileName,
                transcriptFileName: transcriptFileName
            )

            try expect(
                !FileManager.default.fileExists(atPath: savedAudio.fileURL.path),
                "deleteAssets removes the saved audio file"
            )
            let transcriptURL = store.storageLayout.transcriptDirectory
                .appendingPathComponent(transcriptFileName)
            try expect(
                !FileManager.default.fileExists(atPath: transcriptURL.path),
                "deleteAssets removes the saved transcript file"
            )
        }
    }

    private static func testDeleteTranscriptPropagatesNonMissingFileErrors() throws {
        try withTemporaryStore { store in
            let fileName = try store.saveTranscript(
                rawTranscript: "blocked delete",
                postProcessedTranscript: ""
            )
            let directory = store.storageLayout.transcriptDirectory
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o555],
                ofItemAtPath: directory.path
            )
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: directory.path
                )
            }

            do {
                try store.deleteTranscript(fileName: fileName)
                throw TestFailure(
                    "expected deleteTranscript to propagate a permission failure"
                )
            } catch let error as TestFailure {
                throw error
            } catch is NoteAssetStoreError {
                throw TestFailure(
                    "deleteTranscript should propagate the underlying FileManager error directly"
                )
            } catch {
                // expected: the underlying FileManager error propagates directly
            }
        }
    }

    private static func testDeleteAudioPropagatesNonMissingFileErrors() throws {
        try withTemporaryStore { store in
            let sourceURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("note-asset-store-blocked-delete-\(UUID().uuidString).wav")
            try Data("fixture".utf8).write(to: sourceURL)
            defer { try? FileManager.default.removeItem(at: sourceURL) }
            let saved = try store.saveAudio(from: sourceURL)

            let directory = store.storageLayout.audioDirectory
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o555],
                ofItemAtPath: directory.path
            )
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: directory.path
                )
            }

            do {
                try store.deleteAudio(fileName: saved.fileName)
                throw TestFailure(
                    "expected deleteAudio to propagate a permission failure"
                )
            } catch let error as TestFailure {
                throw error
            } catch is NoteAssetStoreError {
                throw TestFailure(
                    "deleteAudio should propagate the underlying FileManager error directly"
                )
            } catch {
                // expected: the underlying FileManager error propagates directly
            }
        }
    }

    private static func testDeleteAssetsStillDeletesTranscriptWhenAudioDeleteFails() throws {
        try withTemporaryStore { store in
            let transcriptFileName = try store.saveTranscript(
                rawTranscript: "still deleted",
                postProcessedTranscript: ""
            )
            let sourceURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("note-asset-store-partial-\(UUID().uuidString).wav")
            try Data("fixture".utf8).write(to: sourceURL)
            defer { try? FileManager.default.removeItem(at: sourceURL) }
            let savedAudio = try store.saveAudio(from: sourceURL)

            let audioDirectory = store.storageLayout.audioDirectory
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o555],
                ofItemAtPath: audioDirectory.path
            )
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: audioDirectory.path
                )
            }

            do {
                try store.deleteAssets(
                    audioFileName: savedAudio.fileName,
                    transcriptFileName: transcriptFileName
                )
                throw TestFailure("expected deleteAssets to propagate the audio deletion failure")
            } catch let error as TestFailure {
                throw error
            } catch {
                // expected: the blocked audio deletion still surfaces a failure
            }

            let transcriptURL = store.storageLayout.transcriptDirectory
                .appendingPathComponent(transcriptFileName)
            try expect(
                !FileManager.default.fileExists(atPath: transcriptURL.path),
                "deleteAssets still deletes the transcript even when the audio deletion fails"
            )
            try expect(
                FileManager.default.fileExists(atPath: savedAudio.fileURL.path),
                "the blocked audio file remains because its directory could not be modified"
            )
        }
    }

    private static func testDeleteRejectsParentDirectoryTraversal() throws {
        try withTemporaryStore { store in
            let siblingURL = store.storageLayout.rootDirectory
                .appendingPathComponent("outside.wav")
            try Data("preserve".utf8).write(to: siblingURL)

            try store.deleteAudio(fileName: "../outside.wav")
            try store.deleteTranscript(fileName: "../outside.wav")

            try expect(
                FileManager.default.fileExists(atPath: siblingURL.path),
                "asset deletion cannot escape its storage directory"
            )
        }
    }

    private static func testLoadTranscriptRejectsParentDirectoryTraversal() throws {
        try withTemporaryStore { store in
            let siblingURL = store.storageLayout.rootDirectory
                .appendingPathComponent("outside.txt")
            try Data("private".utf8).write(to: siblingURL)

            do {
                _ = try store.loadTranscript(fileName: "../outside.txt")
                throw TestFailure(
                    "expected parent-directory transcript load to fail"
                )
            } catch let error as TestFailure {
                throw error
            } catch is NoteAssetStoreError {
                // expected
            }
        }
    }

    private static func testStoredAudioURLRejectsParentDirectoryTraversal() throws {
        try withTemporaryStore { store in
            let item = makeItem(audioFileName: "../outside.wav")
            try expect(
                store.storedAudioURL(for: item) == nil,
                "stored audio resolution cannot escape its directory"
            )
        }
    }

    private static func testSweepOrphansPreservesReferencedAndProtectedAssets() throws {
        try withTemporaryStore { store in
            let referencedAudioURL = store.storageLayout.audioDirectory
                .appendingPathComponent("referenced.wav")
            let protectedAudioURL = store.storageLayout.audioDirectory
                .appendingPathComponent("protected.wav")
            let inflightDirectory = store.storageLayout.audioDirectory
                .appendingPathComponent("inflight", isDirectory: true)
            let referencedTranscriptURL = store.storageLayout.transcriptDirectory
                .appendingPathComponent("referenced.txt")
            for fileURL in [
                referencedAudioURL,
                protectedAudioURL,
                referencedTranscriptURL
            ] {
                try Data("fixture".utf8).write(to: fileURL)
                try setModificationDate(
                    of: fileURL,
                    to: Date(timeIntervalSince1970: 0)
                )
            }
            try FileManager.default.createDirectory(
                at: inflightDirectory,
                withIntermediateDirectories: true
            )

            store.sweepOrphans(
                referencedAudioFileNames: [referencedAudioURL.lastPathComponent],
                referencedTranscriptFileNames: [
                    referencedTranscriptURL.lastPathComponent
                ],
                protectedInflightAudioFileNames: [
                    protectedAudioURL.lastPathComponent
                ],
                referenceTrust: .complete,
                now: Date(timeIntervalSince1970: 301)
            )

            for fileURL in [
                referencedAudioURL,
                protectedAudioURL,
                inflightDirectory,
                referencedTranscriptURL
            ] {
                try expect(
                    FileManager.default.fileExists(atPath: fileURL.path),
                    "orphan sweep preserves referenced and protected assets"
                )
            }
        }
    }

    private static func testSweepOrphansPreservesRecentAssets() throws {
        try withTemporaryStore { store in
            let recentAudioURL = store.storageLayout.audioDirectory
                .appendingPathComponent("recent.wav")
            let recentTranscriptURL = store.storageLayout.transcriptDirectory
                .appendingPathComponent("recent.txt")
            let modificationDate = Date(timeIntervalSince1970: 2)
            for fileURL in [recentAudioURL, recentTranscriptURL] {
                try Data("fixture".utf8).write(to: fileURL)
                try setModificationDate(of: fileURL, to: modificationDate)
            }

            store.sweepOrphans(
                referencedAudioFileNames: [],
                referencedTranscriptFileNames: [],
                protectedInflightAudioFileNames: [],
                referenceTrust: .complete,
                now: Date(timeIntervalSince1970: 302)
            )

            for fileURL in [recentAudioURL, recentTranscriptURL] {
                try expect(
                    FileManager.default.fileExists(atPath: fileURL.path),
                    "orphan sweep preserves assets at the 300-second boundary"
                )
            }
        }
    }

    private static func testSweepOrphansDeletesOldUnreferencedAssets() throws {
        try withTemporaryStore { store in
            let oldAudioURL = store.storageLayout.audioDirectory
                .appendingPathComponent("old.wav")
            let oldTranscriptURL = store.storageLayout.transcriptDirectory
                .appendingPathComponent("old.txt")
            for fileURL in [oldAudioURL, oldTranscriptURL] {
                try Data("fixture".utf8).write(to: fileURL)
                try setModificationDate(
                    of: fileURL,
                    to: Date(timeIntervalSince1970: 0)
                )
            }

            store.sweepOrphans(
                referencedAudioFileNames: [],
                referencedTranscriptFileNames: [],
                protectedInflightAudioFileNames: [],
                referenceTrust: .complete,
                now: Date(timeIntervalSince1970: 301)
            )

            for fileURL in [oldAudioURL, oldTranscriptURL] {
                try expect(
                    !FileManager.default.fileExists(atPath: fileURL.path),
                    "orphan sweep deletes assets older than 300 seconds"
                )
            }
        }
    }

    private static func testSweepOrphansRequiresTrustedReferences() throws {
        for trust in [
            PipelineHistoryReferenceTrust.recovered,
            PipelineHistoryReferenceTrust.unavailable
        ] {
            try withTemporaryStore { store in
                let oldAudioURL = store.storageLayout.audioDirectory
                    .appendingPathComponent("untrusted-\(UUID().uuidString).wav")
                try Data("fixture".utf8).write(to: oldAudioURL)
                try setModificationDate(
                    of: oldAudioURL,
                    to: Date(timeIntervalSince1970: 0)
                )

                store.sweepOrphans(
                    referencedAudioFileNames: [],
                    referencedTranscriptFileNames: [],
                    protectedInflightAudioFileNames: [],
                    referenceTrust: trust,
                    now: Date(timeIntervalSince1970: 301)
                )

                try expect(
                    FileManager.default.fileExists(atPath: oldAudioURL.path),
                    "orphan sweep skips cleanup without complete reference trust"
                )
            }
        }
    }

    private static func setModificationDate(
        of fileURL: URL,
        to date: Date
    ) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: date],
            ofItemAtPath: fileURL.path
        )
    }

    private static func testStoredAudioURLResolvesFromItem() throws {
        try withTemporaryStore { store in
            let item = makeItem(audioFileName: "resolved.wav")
            let resolved = store.storedAudioURL(for: item)
            try expect(
                resolved == store.storageLayout.audioDirectory.appendingPathComponent("resolved.wav"),
                "storedAudioURL resolves under the store's own audio directory"
            )
        }
    }

    private static func testStoredAudioURLIsNilWithoutAudioFileName() throws {
        try withTemporaryStore { store in
            let item = makeItem(audioFileName: nil)
            try expect(
                store.storedAudioURL(for: item) == nil,
                "storedAudioURL is nil when the item has no audio file name"
            )
        }
    }

    private static func testPrepareDirectoriesCreatesAudioAndTranscriptDirectories() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("note-asset-store-prepare-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NoteAssetStore(storageLayout: AppStateStorageLayout(rootDirectory: root))

        let (audioDirectory, transcriptDirectory) = store.prepareDirectories()

        var isDirectory: ObjCBool = false
        try expect(
            FileManager.default.fileExists(atPath: audioDirectory.path, isDirectory: &isDirectory)
                && isDirectory.boolValue,
            "prepareDirectories creates the audio directory"
        )
        try expect(
            FileManager.default.fileExists(atPath: transcriptDirectory.path, isDirectory: &isDirectory)
                && isDirectory.boolValue,
            "prepareDirectories creates the transcript directory"
        )
    }

    private static func testTwoStoresWithIndependentLayoutsDoNotShareFiles() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("note-asset-store-independent-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let firstStore = NoteAssetStore(
            storageLayout: AppStateStorageLayout(
                rootDirectory: parent.appendingPathComponent("first", isDirectory: true)
            )
        )
        let secondStore = NoteAssetStore(
            storageLayout: AppStateStorageLayout(
                rootDirectory: parent.appendingPathComponent("second", isDirectory: true)
            )
        )
        firstStore.prepareDirectories()
        secondStore.prepareDirectories()

        let firstFileName = try firstStore.saveTranscript(
            rawTranscript: "first store transcript",
            postProcessedTranscript: ""
        )
        let secondFileName = try secondStore.saveTranscript(
            rawTranscript: "second store transcript",
            postProcessedTranscript: ""
        )

        try expect(
            (try? secondStore.loadTranscript(fileName: firstFileName)) == nil,
            "the second store cannot read a transcript saved only in the first store"
        )
        let firstLoaded = try firstStore.loadTranscript(fileName: firstFileName)
        let secondLoaded = try secondStore.loadTranscript(fileName: secondFileName)
        try expect(
            firstLoaded == "first store transcript" && secondLoaded == "second store transcript",
            "each store independently persists and loads its own transcript"
        )
    }

    private static func testOneStoreCannotDeleteAnotherStoresTranscript() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("note-asset-store-delete-isolation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let firstStore = NoteAssetStore(
            storageLayout: AppStateStorageLayout(
                rootDirectory: parent.appendingPathComponent("first", isDirectory: true)
            )
        )
        let secondStore = NoteAssetStore(
            storageLayout: AppStateStorageLayout(
                rootDirectory: parent.appendingPathComponent("second", isDirectory: true)
            )
        )
        firstStore.prepareDirectories()
        secondStore.prepareDirectories()
        let fileName = try firstStore.saveTranscript(
            rawTranscript: "first store",
            postProcessedTranscript: ""
        )

        try secondStore.deleteTranscript(fileName: fileName)

        let originalURL = firstStore.storageLayout.transcriptDirectory
            .appendingPathComponent(fileName)
        try expect(
            FileManager.default.fileExists(atPath: originalURL.path),
            "a different store cannot delete the originating transcript"
        )
    }

    private static func testSaveTranscriptThrowsWhenDirectoryIsUnavailable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("note-asset-store-blocked-transcript-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storageLayout = AppStateStorageLayout(rootDirectory: root)
        // Create a plain file where the transcript directory should be, so
        // FileManager cannot create it and any write into it fails.
        try Data().write(to: storageLayout.transcriptDirectory)
        let store = NoteAssetStore(storageLayout: storageLayout)

        do {
            _ = try store.saveTranscript(rawTranscript: "unwritable", postProcessedTranscript: "")
            throw TestFailure(
                "expected saveTranscript to throw when its directory cannot be created"
            )
        } catch is NoteAssetStoreError {
            // expected
        }
    }

    private static func testSaveAudioThrowsWhenDirectoryIsUnavailable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("note-asset-store-blocked-audio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storageLayout = AppStateStorageLayout(rootDirectory: root)
        try Data().write(to: storageLayout.audioDirectory)
        let store = NoteAssetStore(storageLayout: storageLayout)

        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("note-asset-store-blocked-source-\(UUID().uuidString).wav")
        try Data("fixture".utf8).write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        do {
            _ = try store.saveAudio(from: sourceURL)
            throw TestFailure("expected saveAudio to throw when its directory cannot be created")
        } catch is NoteAssetStoreError {
            // expected
        }
    }

    private static func canonicalWAVData(samples: [Int16]) throws -> Data {
        var payload = Data()
        for sample in samples {
            let value = UInt16(bitPattern: sample)
            payload.append(UInt8(value & 0x00ff))
            payload.append(UInt8(value >> 8))
        }
        var data = try CanonicalPCM16WAV.header(dataByteCount: UInt32(payload.count))
        data.append(payload)
        return data
    }

    private static func audioFileNames(in store: NoteAssetStore) throws -> [String] {
        try FileManager.default.contentsOfDirectory(
            atPath: store.storageLayout.audioDirectory.path
        ).sorted()
    }

    private static func makeItem(audioFileName: String?) -> PipelineHistoryItem {
        PipelineHistoryItem(
            timestamp: Date(),
            rawTranscript: "",
            postProcessedTranscript: "",
            postProcessingPrompt: nil,
            contextSummary: "",
            contextScreenshotDataURL: nil,
            contextScreenshotStatus: "No screenshot",
            postProcessingStatus: "succeeded",
            debugStatus: "",
            customVocabulary: "",
            audioFileName: audioFileName
        )
    }

    private static func withTemporaryStore(
        _ operation: (NoteAssetStore) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("note-asset-store-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NoteAssetStore(storageLayout: AppStateStorageLayout(rootDirectory: root))
        store.prepareDirectories()
        try operation(store)
    }

    private static func withTemporaryStoreAsync(
        _ operation: (NoteAssetStore) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("note-asset-store-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NoteAssetStore(storageLayout: AppStateStorageLayout(rootDirectory: root))
        store.prepareDirectories()
        try await operation(store)
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
