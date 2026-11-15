import Darwin
import Foundation

@main
struct HistoryRecoveryServiceTests {
    static func main() throws {
        try testCatalogsValidSnapshotWithoutChangingSourceBytes()
        try testCatalogRejectsTraversalComponent()
        try testCatalogRejectsNonDirectoryAudioComponent()
        try testCatalogRejectsDuplicateComponent()
        try testCatalogShowsCorruptManifestForManualManagement()
        try testCatalogRejectsSymbolicLinkPayload()
        try testCatalogCountsHiddenPayloadFiles()
        try testCatalogRejectsSymbolicLinkSnapshot()
        try testUnreadableSnapshotInspectionPersistsFailureWithoutChangingSource()
        try testSuccessfulReinspectionRestoresPriorSnapshotStatus()
        try testInspectionAgainstAListHoldingAnIDTwiceDoesNotTrap()
        try testInvalidSnapshotInspectionDoesNotWriteFailureState()
        try testLogicalComparisonIgnoresOnlyDestinationAssetNames()
        try testStateWritesReplacePriorStateAtomically()
        try testDurableWriteRetriesInterruptedAndWouldBlockWrites()
        try testDurableWriteRejectsNonRetryableWriteFailure()
        try testImportCopiesAssetsAndRetriesWithoutDuplicates()
        try testImportDoesNotReuseUnsafePersistedAssetName()
        try testImportMarksUnsafeSourceAssetRecordFailedAndContinues()
        try testImportMarksMismatchedDestinationRecordFailedAndContinues()
        try testImportKeepsCurrentRecordOnUUIDConflict()
        try testCompletedSnapshotRetentionCanBeCancelled()
        try testInvalidSnapshotCannotCancelScheduledDeletion()
        try testExplicitDeletionRemovesSnapshotAndState()
        try testRetentionDeletesOnlyCompletedSnapshotAfterSevenDays()
        print("HistoryRecoveryServiceTests passed")
    }

    private static func testCatalogsValidSnapshotWithoutChangingSourceBytes() throws {
        let fixture = try HistoryRecoveryFixture()
        defer { fixture.remove() }
        let snapshot = try fixture.writeSnapshot()
        let manifestURL = snapshot.appendingPathComponent("manifest.json")
        let sqliteURL = snapshot.appendingPathComponent("payload/PipelineHistory.sqlite")
        let originalManifest = try Data(contentsOf: manifestURL)
        let originalSQLite = try Data(contentsOf: sqliteURL)

        let service = HistoryRecoveryService(storageRoot: fixture.rootURL)
        let descriptors = service.listSnapshots()

        try expect(descriptors.count == 1, "catalog finds the published snapshot")
        try expect(descriptors[0].integrity == .ready, "valid snapshot is ready for inspection")
        try expect(descriptors[0].snapshot.id == fixture.snapshotID, "catalog keeps manifest identity")
        let currentManifest = try Data(contentsOf: manifestURL)
        let currentSQLite = try Data(contentsOf: sqliteURL)
        try expect(
            currentManifest == originalManifest && currentSQLite == originalSQLite,
            "catalog never changes source manifest or payload bytes"
        )
    }

    private static func testCatalogRejectsTraversalComponent() throws {
        let fixture = try HistoryRecoveryFixture()
        defer { fixture.remove() }
        let snapshot = try fixture.writeSnapshot(
            components: [
                HistoryArchiveSnapshotComponent(
                    identifier: .sqlite,
                    relativePath: "../PipelineHistory.sqlite",
                    byteCount: 0,
                    isDirectory: false
                )
            ]
        )
        let service = HistoryRecoveryService(storageRoot: fixture.rootURL)

        let descriptor = try required(service.listSnapshots().first)
        try expect(snapshot.lastPathComponent.hasPrefix("history-"), "fixture published snapshot is named")
        try expect(descriptor.integrity == .invalid, "traversal component is never importable")
    }

    private static func testCatalogRejectsNonDirectoryAudioComponent() throws {
        let fixture = try HistoryRecoveryFixture()
        defer { fixture.remove() }
        let snapshotURL = try fixture.writeSnapshot()
        let payloadURL = snapshotURL.appendingPathComponent("payload", isDirectory: true)
        let audioBytes = Data("not an audio directory".utf8)
        try audioBytes.write(to: payloadURL.appendingPathComponent("audio"))
        let manifestURL = snapshotURL.appendingPathComponent("manifest.json")
        let manifest = try JSONDecoder().decode(
            HistoryArchiveSnapshot.self,
            from: Data(contentsOf: manifestURL)
        )
        let malformedManifest = HistoryArchiveSnapshot(
            schemaVersion: manifest.schemaVersion,
            id: manifest.id,
            archivedAt: manifest.archivedAt,
            components: manifest.components + [
                HistoryArchiveSnapshotComponent(
                    identifier: .audio,
                    relativePath: "audio",
                    byteCount: UInt64(audioBytes.count),
                    isDirectory: false
                )
            ]
        )
        try JSONEncoder().encode(malformedManifest).write(to: manifestURL)

        let descriptor = try required(HistoryRecoveryService(storageRoot: fixture.rootURL).listSnapshots().first)
        try expect(
            descriptor.integrity == .invalid,
            "a published audio file is not a recoverable audio directory component"
        )
    }

    private static func testCatalogRejectsDuplicateComponent() throws {
        let fixture = try HistoryRecoveryFixture()
        defer { fixture.remove() }
        let snapshotURL = try fixture.writeSnapshot()
        let manifestURL = snapshotURL.appendingPathComponent("manifest.json")
        let manifest = try JSONDecoder().decode(
            HistoryArchiveSnapshot.self,
            from: Data(contentsOf: manifestURL)
        )
        let malformedManifest = HistoryArchiveSnapshot(
            schemaVersion: manifest.schemaVersion,
            id: manifest.id,
            archivedAt: manifest.archivedAt,
            components: manifest.components + [try required(manifest.components.first)]
        )
        try JSONEncoder().encode(malformedManifest).write(to: manifestURL)

        let descriptor = try required(HistoryRecoveryService(storageRoot: fixture.rootURL).listSnapshots().first)
        try expect(
            descriptor.integrity == .invalid,
            "duplicate archive component declarations are not a recovery source"
        )
    }

    private static func testCatalogShowsCorruptManifestForManualManagement() throws {
        let fixture = try HistoryRecoveryFixture()
        defer { fixture.remove() }
        _ = try fixture.writeCorruptSnapshot()
        let service = HistoryRecoveryService(storageRoot: fixture.rootURL)

        let descriptor = try required(service.listSnapshots().first)
        try expect(
            descriptor.id == fixture.snapshotID && descriptor.integrity == .invalid,
            "a corrupt published snapshot stays visible for manual deletion"
        )
    }

    private static func testCatalogRejectsSymbolicLinkPayload() throws {
        let fixture = try HistoryRecoveryFixture()
        defer { fixture.remove() }
        let snapshotURL = try fixture.writeSnapshot()
        let payloadURL = snapshotURL.appendingPathComponent("payload", isDirectory: true)
        let audioDirectory = payloadURL.appendingPathComponent("audio", isDirectory: true)
        let outsideURL = fixture.rootURL.appendingPathComponent("outside.wav")
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: outsideURL)
        try FileManager.default.createSymbolicLink(
            at: audioDirectory.appendingPathComponent("linked.wav"),
            withDestinationURL: outsideURL
        )
        let manifestURL = snapshotURL.appendingPathComponent("manifest.json")
        var manifest = try JSONDecoder().decode(
            HistoryArchiveSnapshot.self,
            from: Data(contentsOf: manifestURL)
        )
        manifest = HistoryArchiveSnapshot(
            schemaVersion: manifest.schemaVersion,
            id: manifest.id,
            archivedAt: manifest.archivedAt,
            components: manifest.components + [
                HistoryArchiveSnapshotComponent(
                    identifier: .audio,
                    relativePath: "audio",
                    byteCount: 0,
                    isDirectory: true
                )
            ]
        )
        try JSONEncoder().encode(manifest).write(to: manifestURL)

        let descriptor = try required(HistoryRecoveryService(storageRoot: fixture.rootURL).listSnapshots().first)
        try expect(descriptor.integrity == .invalid, "symbolic link payload is not a recovery source")
    }

    private static func testCatalogCountsHiddenPayloadFiles() throws {
        let fixture = try HistoryRecoveryFixture()
        defer { fixture.remove() }
        let snapshotURL = try fixture.writeSnapshot()
        let payloadURL = snapshotURL.appendingPathComponent("payload", isDirectory: true)
        let audioDirectory = payloadURL.appendingPathComponent("audio", isDirectory: true)
        let hiddenAudio = Data("hidden audio".utf8)
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        try hiddenAudio.write(to: audioDirectory.appendingPathComponent(".hidden.wav"))

        let manifestURL = snapshotURL.appendingPathComponent("manifest.json")
        let manifest = try JSONDecoder().decode(
            HistoryArchiveSnapshot.self,
            from: Data(contentsOf: manifestURL)
        )
        let manifestWithHiddenAudio = HistoryArchiveSnapshot(
            schemaVersion: manifest.schemaVersion,
            id: manifest.id,
            archivedAt: manifest.archivedAt,
            components: manifest.components + [
                HistoryArchiveSnapshotComponent(
                    identifier: .audio,
                    relativePath: "audio",
                    byteCount: UInt64(hiddenAudio.count),
                    isDirectory: true
                )
            ]
        )
        try JSONEncoder().encode(manifestWithHiddenAudio).write(to: manifestURL)

        let descriptor = try required(HistoryRecoveryService(storageRoot: fixture.rootURL).listSnapshots().first)
        try expect(
            descriptor.integrity == .ready,
            "hidden payload files included in the archive byte count remain recoverable"
        )
    }

    private static func testCatalogRejectsSymbolicLinkSnapshot() throws {
        let fixture = try HistoryRecoveryFixture()
        defer { fixture.remove() }
        let snapshotURL = try fixture.writeSnapshot()
        let externalSnapshotURL = fixture.rootURL.appendingPathComponent("external-snapshot")
        try FileManager.default.moveItem(at: snapshotURL, to: externalSnapshotURL)
        try FileManager.default.createSymbolicLink(
            at: snapshotURL,
            withDestinationURL: externalSnapshotURL
        )

        let descriptor = try required(HistoryRecoveryService(storageRoot: fixture.rootURL).listSnapshots().first)
        try expect(
            descriptor.integrity == .invalid,
            "a symbolic-link snapshot is never treated as a recovery source"
        )
    }

    private static func testUnreadableSnapshotInspectionPersistsFailureWithoutChangingSource() throws {
        let fixture = try HistoryRecoveryFixture()
        defer { fixture.remove() }
        let snapshotURL = try fixture.writeSnapshot()
        let manifestURL = snapshotURL.appendingPathComponent("manifest.json")
        let sqliteURL = snapshotURL.appendingPathComponent("payload/PipelineHistory.sqlite")
        let originalManifest = try Data(contentsOf: manifestURL)
        let originalSQLite = try Data(contentsOf: sqliteURL)
        let service = HistoryRecoveryService(storageRoot: fixture.rootURL)

        do {
            _ = try service.inspectSnapshot(id: fixture.snapshotID, against: [])
            throw HistoryRecoveryTestFailure("unreadable snapshot inspection unexpectedly succeeded")
        } catch HistoryRecoveryServiceError.snapshotNotReady {
            // Expected: the fixture has a structurally valid but unreadable SQLite payload.
        }

        let descriptor = try required(service.listSnapshots().first)
        try expect(
            descriptor.state?.status == .inspectionFailed,
            "unreadable snapshot inspection remains visible as a durable failure"
        )
        let currentManifest = try Data(contentsOf: manifestURL)
        let currentSQLite = try Data(contentsOf: sqliteURL)
        try expect(
            currentManifest == originalManifest && currentSQLite == originalSQLite,
            "inspection failure never changes the source manifest or database"
        )
    }

    // #840: a lookup over the current notes trapped when two rows shared an id.
    private static func testInspectionAgainstAListHoldingAnIDTwiceDoesNotTrap() throws {
        let fixture = try HistoryRecoveryFixture()
        defer { fixture.remove() }
        let sourceItem = makeHistoryItem(
            id: fixture.snapshotID,
            audioFileName: "archived.wav",
            transcriptFileName: "archived.txt"
        )
        _ = try fixture.writeHistorySnapshot(item: sourceItem)
        let service = HistoryRecoveryService(storageRoot: fixture.rootURL)

        let inspection = try service.inspectSnapshot(id: fixture.snapshotID, against: [sourceItem, sourceItem])

        try expect(inspection.readableRecordCount == 1, "the archived note is read")
        try expect(inspection.alreadyPresentRecordCount == 1, "the repeated current note counts once")
    }

    private static func testSuccessfulReinspectionRestoresPriorSnapshotStatus() throws {
        let fixture = try HistoryRecoveryFixture()
        defer { fixture.remove() }
        let sourceItem = makeHistoryItem(
            id: fixture.snapshotID,
            audioFileName: "archived.wav",
            transcriptFileName: "archived.txt"
        )
        _ = try fixture.writeHistorySnapshot(item: sourceItem)
        let completedAt = Date(timeIntervalSince1970: 1_754_010_203)
        let service = HistoryRecoveryService(storageRoot: fixture.rootURL)
        try service.saveState(
            HistoryRecoveryState(
                snapshotID: fixture.snapshotID,
                status: .inspectionFailed,
                completedAt: completedAt,
                statusBeforeInspectionFailure: .completed
            )
        )

        let inspection = try service.inspectSnapshot(id: fixture.snapshotID, against: [])
        let restoredState = try required(service.listSnapshots().first?.state)

        try expect(inspection.readableRecordCount == 1, "reinspection reads the recovered archive note")
        try expect(
            restoredState.status == .completed
                && restoredState.completedAt == completedAt
                && restoredState.statusBeforeInspectionFailure == nil,
            "successful reinspection restores completed retention state"
        )
    }

    private static func testInvalidSnapshotInspectionDoesNotWriteFailureState() throws {
        let fixture = try HistoryRecoveryFixture()
        defer { fixture.remove() }
        _ = try fixture.writeCorruptSnapshot()
        let service = HistoryRecoveryService(storageRoot: fixture.rootURL)

        do {
            _ = try service.inspectSnapshot(id: fixture.snapshotID, against: [])
            throw HistoryRecoveryTestFailure("invalid snapshot inspection unexpectedly succeeded")
        } catch HistoryRecoveryServiceError.snapshotNotReady {
            // Expected: invalid layouts are never inspection-failed recovery states.
        }

        try expect(
            !FileManager.default.fileExists(atPath: service.stateURL(for: fixture.snapshotID).path),
            "invalid manifest snapshots never gain a recovery inspection state"
        )
    }

    private static func testLogicalComparisonIgnoresOnlyDestinationAssetNames() throws {
        let id = UUID(uuidString: "4B5A73C8-59D4-4FDF-ABF7-2CD61094E3A8")!
        let source = makeHistoryItem(
            id: id,
            audioFileName: "archived.wav",
            transcriptFileName: "archived.txt"
        )
        let remapped = source.replacingAssetFileNames(
            audioFileName: "active.wav",
            transcriptFileName: "active.txt"
        )
        let changed = PipelineHistoryItem(
            id: id,
            timestamp: source.timestamp,
            rawTranscript: "changed text",
            postProcessedTranscript: source.postProcessedTranscript,
            postProcessingPrompt: source.postProcessingPrompt,
            contextSummary: source.contextSummary,
            contextScreenshotDataURL: source.contextScreenshotDataURL,
            contextScreenshotStatus: source.contextScreenshotStatus,
            postProcessingStatus: source.postProcessingStatus,
            debugStatus: source.debugStatus,
            customVocabulary: source.customVocabulary,
            audioFileName: "active.wav",
            transcriptFileName: "active.txt"
        )

        try expect(
            source.isLogicallyEquivalentForHistoryRecovery(to: remapped),
            "recovery equivalence ignores only remapped asset filenames"
        )
        try expect(
            !source.isLogicallyEquivalentForHistoryRecovery(to: changed),
            "recovery equivalence preserves every logical note field"
        )
    }

    private static func testStateWritesReplacePriorStateAtomically() throws {
        let fixture = try HistoryRecoveryFixture()
        defer { fixture.remove() }
        _ = try fixture.writeSnapshot()
        let completedAt = Date(timeIntervalSince1970: 1_754_010_203)
        let service = HistoryRecoveryService(storageRoot: fixture.rootURL)
        try service.saveState(
            HistoryRecoveryState(
                snapshotID: fixture.snapshotID,
                status: .available,
                completedAt: nil
            )
        )
        try service.saveState(
            HistoryRecoveryState(
                snapshotID: fixture.snapshotID,
                status: .completed,
                completedAt: completedAt
            )
        )

        let state = try required(service.listSnapshots().first?.state)
        try expect(
            state.status == .completed && state.completedAt == completedAt,
            "a later durable state replaces the earlier state for one snapshot"
        )
    }

    private static func testDurableWriteRetriesInterruptedAndWouldBlockWrites() throws {
        let bytes = Data([1, 2, 3, 4])
        var writes: [Data] = []
        var attempts = 0

        try HistoryRecoveryDurability.writeAll(bytes) { pointer, remaining in
            defer { attempts += 1 }
            switch attempts {
            case 0:
                return (written: 0, errorCode: EINTR)
            case 1:
                writes.append(Data(bytes: pointer, count: 2))
                return (written: 2, errorCode: 0)
            case 2:
                return (written: 0, errorCode: EAGAIN)
            default:
                writes.append(Data(bytes: pointer, count: remaining))
                return (written: remaining, errorCode: 0)
            }
        }

        try expect(
            attempts == 4 && writes == [Data([1, 2]), Data([3, 4])],
            "durable recovery writes retry interruptions without advancing their buffer"
        )
    }

    private static func testDurableWriteRejectsNonRetryableWriteFailure() throws {
        do {
            try HistoryRecoveryDurability.writeAll(Data([1])) { _, _ in
                (written: 0, errorCode: EIO)
            }
            throw HistoryRecoveryTestFailure("non-retryable durable write unexpectedly succeeded")
        } catch HistoryRecoveryServiceError.metadataWriteFailed {
            // Expected: only EINTR and EAGAIN are retried.
        }
    }

    private static func testImportCopiesAssetsAndRetriesWithoutDuplicates() throws {
        let fixture = try HistoryRecoveryFixture()
        defer { fixture.remove() }
        let sourceItem = makeHistoryItem(
            id: fixture.snapshotID,
            audioFileName: "archived.wav",
            transcriptFileName: "archived.txt"
        )
        let snapshot = try fixture.writeHistorySnapshot(item: sourceItem)
        let archiveAudioURL = snapshot.appendingPathComponent("payload/audio/archived.wav")
        let archiveTranscriptURL = snapshot.appendingPathComponent("payload/transcripts/archived.txt")
        let archiveStoreURL = snapshot.appendingPathComponent("payload/PipelineHistory.sqlite")
        let originalManifest = try Data(contentsOf: snapshot.appendingPathComponent("manifest.json"))
        let originalStore = try Data(contentsOf: archiveStoreURL)
        let originalAudio = try Data(contentsOf: archiveAudioURL)
        let originalTranscript = try Data(contentsOf: archiveTranscriptURL)
        let activeStore = PipelineHistoryStore(storeURL: fixture.activeStoreURL)
        defer { try? activeStore.detachForArchiveVerification() }
        try FileManager.default.createDirectory(
            at: fixture.activeAudioDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: fixture.activeTranscriptDirectory,
            withIntermediateDirectories: true
        )
        let service = HistoryRecoveryService(storageRoot: fixture.rootURL)

        let first = try service.importSnapshot(
            id: fixture.snapshotID,
            into: activeStore,
            audioDirectory: fixture.activeAudioDirectory,
            transcriptDirectory: fixture.activeTranscriptDirectory
        )
        let firstItem = try required(activeStore.loadAllHistory().first)
        let second = try service.importSnapshot(
            id: fixture.snapshotID,
            into: activeStore,
            audioDirectory: fixture.activeAudioDirectory,
            transcriptDirectory: fixture.activeTranscriptDirectory
        )

        try expect(first.importedRecordCount == 1, "first import adds the archived note")
        try expect(second.importedRecordCount == 0, "retry does not add a duplicate note")
        try expect(
            activeStore.loadAllHistory().filter { $0.id == sourceItem.id }.count == 1,
            "retry keeps one active row for the archived UUID"
        )
        try expect(
            firstItem.audioFileName != sourceItem.audioFileName
                && firstItem.transcriptFileName != sourceItem.transcriptFileName,
            "import remaps archive asset filenames before active history owns them"
        )
        let copiedAudio = fixture.activeAudioDirectory.appendingPathComponent(
            try required(firstItem.audioFileName)
        )
        let copiedTranscript = fixture.activeTranscriptDirectory.appendingPathComponent(
            try required(firstItem.transcriptFileName)
        )
        let copiedAudioData = try Data(contentsOf: copiedAudio)
        let copiedTranscriptData = try Data(contentsOf: copiedTranscript)
        try expect(
            copiedAudioData == originalAudio && copiedTranscriptData == originalTranscript,
            "import copies archive assets into active storage"
        )
        let currentArchiveAudio = try Data(contentsOf: archiveAudioURL)
        let currentArchiveTranscript = try Data(contentsOf: archiveTranscriptURL)
        try expect(
            currentArchiveAudio == originalAudio && currentArchiveTranscript == originalTranscript,
            "import never changes source archive assets"
        )
        let currentManifest = try Data(contentsOf: snapshot.appendingPathComponent("manifest.json"))
        let currentStore = try Data(contentsOf: archiveStoreURL)
        try expect(
            currentManifest == originalManifest && currentStore == originalStore,
            "Core Data opens only a scratch copy of the archive database"
        )
        try expect(
            service.listSnapshots().first?.state?.status == .completed,
            "fully imported snapshot becomes eligible for seven-day retention"
        )
    }

    private static func testImportDoesNotReuseUnsafePersistedAssetName() throws {
        let fixture = try HistoryRecoveryFixture()
        defer { fixture.remove() }
        let sourceItem = makeHistoryItem(
            id: UUID(uuidString: "1F9E66D3-7B9B-4E25-BE5B-1392C339C2A7")!,
            audioFileName: "archived.wav",
            transcriptFileName: "archived.txt"
        )
        _ = try fixture.writeHistorySnapshot(item: sourceItem)
        let activeStore = PipelineHistoryStore(storeURL: fixture.activeStoreURL)
        defer { try? activeStore.detachForArchiveVerification() }
        try FileManager.default.createDirectory(
            at: fixture.activeAudioDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: fixture.activeTranscriptDirectory,
            withIntermediateDirectories: true
        )
        let outsideURL = fixture.rootURL.appendingPathComponent("outside.wav")
        let outsideBytes = Data("archived audio".utf8)
        try outsideBytes.write(to: outsideURL)
        let service = HistoryRecoveryService(storageRoot: fixture.rootURL)
        try service.saveState(
            HistoryRecoveryState(
                snapshotID: fixture.snapshotID,
                status: .available,
                records: [
                    HistoryRecoveryRecordState(
                        id: sourceItem.id,
                        status: .planned,
                        audioFileName: "../outside.wav"
                    )
                ],
                completedAt: nil
            )
        )

        _ = try service.importSnapshot(
            id: fixture.snapshotID,
            into: activeStore,
            audioDirectory: fixture.activeAudioDirectory,
            transcriptDirectory: fixture.activeTranscriptDirectory
        )

        let importedItem = try required(activeStore.loadAllHistory().first)
        try expect(
            importedItem.audioFileName != "../outside.wav",
            "a persisted recovery mapping cannot escape the active audio directory"
        )
        try expect(
            try Data(contentsOf: outsideURL) == outsideBytes,
            "an unsafe persisted recovery mapping leaves files outside active storage untouched"
        )
    }

    private static func testImportMarksUnsafeSourceAssetRecordFailedAndContinues() throws {
        let fixture = try HistoryRecoveryFixture()
        defer { fixture.remove() }
        let invalidSourceItem = makeHistoryItem(
            id: UUID(uuidString: "E56DF956-EC51-4085-A398-C1171B0B7973")!,
            audioFileName: "../escape.wav",
            transcriptFileName: "archived.txt"
        )
        let validSourceItem = makeHistoryItem(
            id: UUID(uuidString: "840E1C87-A4B2-4B1F-8B38-EE356CD4DD2B")!,
            audioFileName: "archived.wav",
            transcriptFileName: "archived.txt"
        )
        _ = try fixture.writeHistorySnapshot(items: [invalidSourceItem, validSourceItem])
        let activeStore = PipelineHistoryStore(storeURL: fixture.activeStoreURL)
        defer { try? activeStore.detachForArchiveVerification() }
        let service = HistoryRecoveryService(storageRoot: fixture.rootURL)

        let result = try service.importSnapshot(
            id: fixture.snapshotID,
            into: activeStore,
            audioDirectory: fixture.activeAudioDirectory,
            transcriptDirectory: fixture.activeTranscriptDirectory
        )

        try expect(result.importedRecordCount == 1, "a valid archive record imports after a bad asset name")
        try expect(result.failedRecordCount == 1, "an unsafe source asset name marks only its record failed")
        try expect(
            activeStore.loadAllHistory().contains(where: { $0.id == validSourceItem.id })
                && !activeStore.loadAllHistory().contains(where: { $0.id == invalidSourceItem.id }),
            "unsafe archive asset paths cannot create an active history record"
        )
        let records = try required(service.listSnapshots().first?.state?.records)
        try expect(
            records.first(where: { $0.id == invalidSourceItem.id })?.status == .failed,
            "the unsafe source asset record remains visible for later recovery review"
        )
    }

    private static func testImportMarksMismatchedDestinationRecordFailedAndContinues() throws {
        let fixture = try HistoryRecoveryFixture()
        defer { fixture.remove() }
        let mismatchedDestinationItem = makeHistoryItem(
            id: UUID(uuidString: "3110241E-3DD2-4A9D-B9EC-B3AF85A95C54")!,
            audioFileName: "archived.wav",
            transcriptFileName: "archived.txt"
        )
        let validSourceItem = makeHistoryItem(
            id: UUID(uuidString: "8BA5B1F4-7569-4649-8CAE-CB62831BA52C")!,
            audioFileName: "archived.wav",
            transcriptFileName: "archived.txt"
        )
        _ = try fixture.writeHistorySnapshot(items: [mismatchedDestinationItem, validSourceItem])
        let destinationDirectory = fixture.activeAudioDirectory
            .appendingPathComponent("existing.wav", isDirectory: true)
        try FileManager.default.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )
        try Data("archived audio".utf8).write(
            to: destinationDirectory.appendingPathComponent("same-size.wav")
        )
        let activeStore = PipelineHistoryStore(storeURL: fixture.activeStoreURL)
        defer { try? activeStore.detachForArchiveVerification() }
        let service = HistoryRecoveryService(storageRoot: fixture.rootURL)
        try service.saveState(
            HistoryRecoveryState(
                snapshotID: fixture.snapshotID,
                status: .available,
                records: [
                    HistoryRecoveryRecordState(
                        id: mismatchedDestinationItem.id,
                        status: .planned,
                        audioFileName: "existing.wav"
                    )
                ],
                completedAt: nil
            )
        )

        let result = try service.importSnapshot(
            id: fixture.snapshotID,
            into: activeStore,
            audioDirectory: fixture.activeAudioDirectory,
            transcriptDirectory: fixture.activeTranscriptDirectory
        )

        try expect(result.importedRecordCount == 1, "a valid record imports after a bad destination")
        try expect(result.failedRecordCount == 1, "a directory destination cannot be reused as audio")
        try expect(
            activeStore.loadAllHistory().contains(where: { $0.id == validSourceItem.id })
                && !activeStore.loadAllHistory().contains(where: { $0.id == mismatchedDestinationItem.id }),
            "a mismatched destination cannot create an active history row"
        )
        let records = try required(service.listSnapshots().first?.state?.records)
        try expect(
            records.first(where: { $0.id == mismatchedDestinationItem.id })?.status == .failed,
            "the mismatched destination remains recoverable as a failed record"
        )
    }

    private static func testImportKeepsCurrentRecordOnUUIDConflict() throws {
        let fixture = try HistoryRecoveryFixture()
        defer { fixture.remove() }
        let sourceItem = makeHistoryItem(
            id: fixture.snapshotID,
            audioFileName: "archived.wav",
            transcriptFileName: "archived.txt"
        )
        _ = try fixture.writeHistorySnapshot(item: sourceItem)
        let activeStore = PipelineHistoryStore(storeURL: fixture.activeStoreURL)
        defer { try? activeStore.detachForArchiveVerification() }
        let currentItem = PipelineHistoryItem(
            id: sourceItem.id,
            timestamp: sourceItem.timestamp,
            rawTranscript: "current history text",
            postProcessedTranscript: sourceItem.postProcessedTranscript,
            postProcessingPrompt: sourceItem.postProcessingPrompt,
            contextSummary: sourceItem.contextSummary,
            contextScreenshotDataURL: sourceItem.contextScreenshotDataURL,
            contextScreenshotStatus: sourceItem.contextScreenshotStatus,
            postProcessingStatus: sourceItem.postProcessingStatus,
            debugStatus: sourceItem.debugStatus,
            customVocabulary: sourceItem.customVocabulary
        )
        _ = try activeStore.upsert(currentItem, maxCount: Int.max, requiresDurableStore: true)
        let service = HistoryRecoveryService(storageRoot: fixture.rootURL)

        let result = try service.importSnapshot(
            id: fixture.snapshotID,
            into: activeStore,
            audioDirectory: fixture.activeAudioDirectory,
            transcriptDirectory: fixture.activeTranscriptDirectory
        )

        let preservedItem = try required(activeStore.loadAllHistory().first)
        try expect(result.conflictRecordCount == 1, "differing UUID is reported as a recovery conflict")
        try expect(
            preservedItem.rawTranscript == "current history text",
            "recovery never overwrites the current UUID record"
        )
        try expect(
            service.listSnapshots().first?.state?.status == .partial,
            "a UUID conflict keeps the snapshot out of automatic deletion"
        )
    }

    private static func testCompletedSnapshotRetentionCanBeCancelled() throws {
        let fixture = try HistoryRecoveryFixture()
        defer { fixture.remove() }
        let snapshotURL = try fixture.writeSnapshot()
        let completedAt = Date(timeIntervalSince1970: 1_754_010_203)
        let service = HistoryRecoveryService(
            storageRoot: fixture.rootURL,
            now: { completedAt.addingTimeInterval(8 * 24 * 60 * 60) }
        )
        try service.saveState(
            HistoryRecoveryState(
                snapshotID: fixture.snapshotID,
                status: .completed,
                completedAt: completedAt
            )
        )

        try service.cancelScheduledDeletion(for: fixture.snapshotID)
        let removed = try service.removeExpiredCompletedSnapshots()

        try expect(removed.isEmpty, "cancelled completed snapshot is not auto-deleted")
        try expect(
            FileManager.default.fileExists(atPath: snapshotURL.path)
                && service.listSnapshots().first?.scheduledDeletionAt == nil,
            "cancelled retention remains durable in recovery state"
        )
    }

    private static func testInvalidSnapshotCannotCancelScheduledDeletion() throws {
        let fixture = try HistoryRecoveryFixture()
        defer { fixture.remove() }
        let snapshotURL = try fixture.writeSnapshot()
        let completedAt = Date(timeIntervalSince1970: 1_754_010_203)
        let service = HistoryRecoveryService(storageRoot: fixture.rootURL)
        try service.saveState(
            HistoryRecoveryState(
                snapshotID: fixture.snapshotID,
                status: .completed,
                completedAt: completedAt
            )
        )
        try Data("invalid manifest".utf8).write(
            to: snapshotURL.appendingPathComponent("manifest.json")
        )

        do {
            try service.cancelScheduledDeletion(for: fixture.snapshotID)
            throw HistoryRecoveryTestFailure("invalid snapshot cancellation unexpectedly succeeded")
        } catch HistoryRecoveryServiceError.invalidState {
            // Expected: invalid snapshots allow manual deletion only.
        }

        let state = try required(service.listSnapshots().first?.state)
        try expect(
            state.automaticDeletionCancelledAt == nil,
            "invalid snapshots retain their existing recovery state without mutation"
        )
    }

    private static func testExplicitDeletionRemovesSnapshotAndState() throws {
        let fixture = try HistoryRecoveryFixture()
        defer { fixture.remove() }
        let snapshotURL = try fixture.writeSnapshot()
        let service = HistoryRecoveryService(storageRoot: fixture.rootURL)
        try service.saveState(
            HistoryRecoveryState(
                snapshotID: fixture.snapshotID,
                status: .available,
                completedAt: nil
            )
        )

        try service.deleteSnapshot(id: fixture.snapshotID)

        try expect(
            !FileManager.default.fileExists(atPath: snapshotURL.path)
                && !FileManager.default.fileExists(
                    atPath: service.stateURL(for: fixture.snapshotID).path
                ),
            "explicit deletion removes only the selected snapshot and its state"
        )
    }

    private static func testRetentionDeletesOnlyCompletedSnapshotAfterSevenDays() throws {
        let fixture = try HistoryRecoveryFixture()
        defer { fixture.remove() }
        let completedSnapshot = try fixture.writeSnapshot()
        let partialSnapshot = try fixture.writeSnapshot(id: fixture.partialSnapshotID)
        let completedAt = Date(timeIntervalSince1970: 1_754_010_203)
        let service = HistoryRecoveryService(
            storageRoot: fixture.rootURL,
            now: { completedAt.addingTimeInterval(8 * 24 * 60 * 60) }
        )
        try service.saveState(
            HistoryRecoveryState(
                snapshotID: fixture.snapshotID,
                status: .completed,
                completedAt: completedAt
            )
        )
        try service.saveState(
            HistoryRecoveryState(
                snapshotID: fixture.partialSnapshotID,
                status: .partial,
                completedAt: nil
            )
        )

        let removed = try service.removeExpiredCompletedSnapshots()

        try expect(removed == [fixture.snapshotID], "retention removes only expired completed snapshot")
        try expect(
            !FileManager.default.fileExists(atPath: completedSnapshot.path),
            "expired completed snapshot is removed"
        )
        try expect(
            FileManager.default.fileExists(atPath: partialSnapshot.path),
            "partial snapshot remains preserved"
        )
        try expect(
            !FileManager.default.fileExists(atPath: service.stateURL(for: fixture.snapshotID).path)
                && FileManager.default.fileExists(
                    atPath: service.stateURL(for: fixture.partialSnapshotID).path
                ),
            "retention removes only the completed snapshot state"
        )
    }

    private static func makeHistoryItem(
        id: UUID,
        audioFileName: String?,
        transcriptFileName: String?
    ) -> PipelineHistoryItem {
        PipelineHistoryItem(
            id: id,
            timestamp: Date(timeIntervalSince1970: 1_754_010_203),
            rawTranscript: "source text",
            postProcessedTranscript: "final text",
            postProcessingPrompt: "prompt",
            contextSummary: "summary",
            contextScreenshotDataURL: nil,
            contextScreenshotStatus: "available",
            postProcessingStatus: "complete",
            debugStatus: "",
            customVocabulary: "",
            audioFileName: audioFileName,
            transcriptFileName: transcriptFileName
        )
    }

    private static func required<T>(_ value: T?) throws -> T {
        guard let value else { throw HistoryRecoveryTestFailure("missing required value") }
        return value
    }

    private static func expect(
        _ condition: @autoclosure () throws -> Bool,
        _ label: String
    ) throws {
        guard try condition() else { throw HistoryRecoveryTestFailure(label) }
    }
}

private final class HistoryRecoveryFixture {
    let rootURL: URL
    let snapshotID = UUID(uuidString: "A3E4BA14-2F2E-4724-BFCF-1F8F1667E577")!

    var activeStoreURL: URL {
        rootURL.appendingPathComponent("PipelineHistory.sqlite")
    }

    var activeAudioDirectory: URL {
        rootURL.appendingPathComponent("audio", isDirectory: true)
    }

    var activeTranscriptDirectory: URL {
        rootURL.appendingPathComponent("transcripts", isDirectory: true)
    }
    let partialSnapshotID = UUID(uuidString: "8C5D66A4-6BB3-4A57-A8FD-45D1C08B6C93")!

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    func writeSnapshot(
        id: UUID? = nil,
        components: [HistoryArchiveSnapshotComponent]? = nil
    ) throws -> URL {
        let resolvedID = id ?? snapshotID
        let snapshotURL = rootURL
            .appendingPathComponent("Recovery", isDirectory: true)
            .appendingPathComponent(
                "history-20250801T010323Z-\(resolvedID.uuidString.lowercased())",
                isDirectory: true
            )
        let payloadURL = snapshotURL.appendingPathComponent("payload", isDirectory: true)
        try FileManager.default.createDirectory(at: payloadURL, withIntermediateDirectories: true)
        let sqliteData = Data("SQLite payload".utf8)
        try sqliteData.write(to: payloadURL.appendingPathComponent("PipelineHistory.sqlite"))
        let snapshot = HistoryArchiveSnapshot(
            schemaVersion: HistoryArchiveSnapshot.currentSchemaVersion,
            id: resolvedID,
            archivedAt: Date(timeIntervalSince1970: 1_754_010_203),
            components: components ?? [
                HistoryArchiveSnapshotComponent(
                    identifier: .sqlite,
                    relativePath: "PipelineHistory.sqlite",
                    byteCount: UInt64(sqliteData.count),
                    isDirectory: false
                )
            ]
        )
        try JSONEncoder().encode(snapshot).write(
            to: snapshotURL.appendingPathComponent("manifest.json")
        )
        return snapshotURL
    }

    func writeCorruptSnapshot() throws -> URL {
        let snapshotURL = rootURL
            .appendingPathComponent("Recovery", isDirectory: true)
            .appendingPathComponent(
                "history-20250801T010323Z-\(snapshotID.uuidString.lowercased())",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: snapshotURL.appendingPathComponent("payload", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("not a manifest".utf8).write(
            to: snapshotURL.appendingPathComponent("manifest.json")
        )
        return snapshotURL
    }

    func writeHistorySnapshot(item: PipelineHistoryItem) throws -> URL {
        try writeHistorySnapshot(items: [item])
    }

    func writeHistorySnapshot(items: [PipelineHistoryItem]) throws -> URL {
        let snapshotURL = rootURL
            .appendingPathComponent("Recovery", isDirectory: true)
            .appendingPathComponent(
                "history-20250801T010323Z-\(snapshotID.uuidString.lowercased())",
                isDirectory: true
            )
        let payloadURL = snapshotURL.appendingPathComponent("payload", isDirectory: true)
        let archiveAudioDirectory = payloadURL.appendingPathComponent("audio", isDirectory: true)
        let archiveTranscriptDirectory = payloadURL.appendingPathComponent(
            "transcripts",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: archiveAudioDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: archiveTranscriptDirectory,
            withIntermediateDirectories: true
        )
        try Data("archived audio".utf8).write(
            to: archiveAudioDirectory.appendingPathComponent("archived.wav")
        )
        try Data("archived transcript".utf8).write(
            to: archiveTranscriptDirectory.appendingPathComponent("archived.txt")
        )

        let storeURL = payloadURL.appendingPathComponent("PipelineHistory.sqlite")
        let archiveStore = PipelineHistoryStore(storeURL: storeURL)
        for item in items {
            _ = try archiveStore.upsert(item, maxCount: Int.max, requiresDurableStore: true)
        }
        try archiveStore.detachForArchiveVerification()

        let components = try [
            (HistoryArchiveSnapshotComponent.Identifier.sqlite, "PipelineHistory.sqlite", false),
            (.sqliteWAL, "PipelineHistory.sqlite-wal", false),
            (.sqliteSHM, "PipelineHistory.sqlite-shm", false),
            (.assetReferenceSnapshot, "PipelineHistory-asset-references.json", false),
            (.audio, "audio", true),
            (.transcripts, "transcripts", true)
        ].compactMap { identifier, relativePath, isDirectory -> HistoryArchiveSnapshotComponent? in
            let url = payloadURL.appendingPathComponent(relativePath)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return HistoryArchiveSnapshotComponent(
                identifier: identifier,
                relativePath: relativePath,
                byteCount: try recursiveByteCount(at: url),
                isDirectory: isDirectory
            )
        }
        let snapshot = HistoryArchiveSnapshot(
            schemaVersion: HistoryArchiveSnapshot.currentSchemaVersion,
            id: snapshotID,
            archivedAt: Date(timeIntervalSince1970: 1_754_010_203),
            components: components
        )
        try JSONEncoder().encode(snapshot).write(
            to: snapshotURL.appendingPathComponent("manifest.json")
        )
        return snapshotURL
    }

    private func recursiveByteCount(at url: URL) throws -> UInt64 {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        guard values.isDirectory == true else {
            return UInt64(max(0, values.fileSize ?? 0))
        }
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey]
        ) else {
            return 0
        }
        var total: UInt64 = 0
        for case let childURL as URL in enumerator {
            let childValues = try childURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            guard childValues.isDirectory != true else { continue }
            total += UInt64(max(0, childValues.fileSize ?? 0))
        }
        return total
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private struct HistoryRecoveryTestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
