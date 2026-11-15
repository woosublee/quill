import CoreData
import Foundation

@main
struct PipelineHistoryStoreRecoveryTests {
    static func main() throws {
        try testFreshDurableStoreIsReady()
        try testAssetReferenceSnapshotDetectsHistoryLoss()
        try testMetadataOnlyUpdateDoesNotRewriteAssetSnapshot()
        try testSnapshotSynchronizationFetchesOnlyAssetFileNames()
        try testSnapshotSynchronizationHasOneReferenceTrustGuard()
        try testApplicationSupportDirectoryHasDeterministicFallback()
        try testPublishedArchiveLowersReferenceTrust()
        try testUnfinishedArchiveTransactionDisablesReferenceCleanup()
        try testArchivePreparationDetachesReadFailedStoreWithoutMutatingCanonicalFiles()
        try testArchiveVerificationDetachesReadyStoreWithoutMutatingCanonicalFiles()
        try testUnavailableStorePreservesDatabaseComponentsAndRejectsMutations()
        try testReadFailureEntersProtectionMode()
        try testReadabilityProbeUsesBoundedFetch()
        try testClearAllPropagatesReadFailure()
        try testTrimPropagatesReadFailure()
        try testHealthyHistoryIsRetriedOnNextLaunch()
        try testExplicitInMemoryStoreRejectsDurableWrites()
        try testAppendingAnIDTheStoreHoldsSavesOverThatRow()
        print("PipelineHistoryStoreRecoveryTests passed")
    }

    private static func testFreshDurableStoreIsReady() throws {
        let fixture = try PersistentStoreFixture()
        defer { fixture.remove() }

        let store = PipelineHistoryStore(storeURL: fixture.storeURL)
        try expect(store.availability == .ready, "fresh persistent store is ready")
        try expect(store.durability == .durable, "fresh persistent store is durable")
        try expect(
            store.referenceTrust == .complete,
            "fresh persistent store has complete asset references"
        )
    }

    private static func testAssetReferenceSnapshotDetectsHistoryLoss() throws {
        let fixture = try PersistentStoreFixture()
        defer { fixture.remove() }
        let store = PipelineHistoryStore(storeURL: fixture.storeURL)
        let knownAudioFileNames: Set<String> = ["recording.wav"]

        try expect(
            store.assetReferenceSnapshotState(
                audioFileNames: knownAudioFileNames,
                transcriptFileNames: []
            ) == .missing,
            "a new history store has no reference snapshot"
        )
        try expect(
            store.bootstrapAssetReferenceSnapshot(
                audioFileNames: knownAudioFileNames,
                transcriptFileNames: []
            ),
            "a missing reference snapshot can be seeded without deleting assets"
        )
        try expect(
            store.assetReferenceSnapshotState(
                audioFileNames: knownAudioFileNames,
                transcriptFileNames: []
            ) == .matches,
            "seeded reference snapshots match their history references"
        )
        try expect(
            store.assetReferenceSnapshotState(
                audioFileNames: [],
                transcriptFileNames: []
            ) == .mismatch,
            "missing history rows cannot pass reference validation"
        )
    }

    private static func testMetadataOnlyUpdateDoesNotRewriteAssetSnapshot() throws {
        let fixture = try PersistentStoreFixture()
        defer { fixture.remove() }
        let store = PipelineHistoryStore(storeURL: fixture.storeURL)
        let item = makeHistoryItem()
        _ = try store.upsert(item, maxCount: 10)
        try expect(
            store.bootstrapAssetReferenceSnapshot(audioFileNames: [], transcriptFileNames: []),
            "metadata-only update test seeds a matching asset snapshot"
        )
        let snapshotURL = fixture.directoryURL
            .appendingPathComponent("PipelineHistory-asset-references.json")
        let snapshotDate = Date(timeIntervalSince1970: 1_000)
        try FileManager.default.setAttributes(
            [.modificationDate: snapshotDate],
            ofItemAtPath: snapshotURL.path
        )

        try store.update(item.withCustomTitle("Updated title"))
        let attributes = try FileManager.default.attributesOfItem(atPath: snapshotURL.path)
        guard let modifiedAt = attributes[.modificationDate] as? Date else {
            throw RecoveryTestFailure("missing asset snapshot modification date")
        }
        try expect(
            modifiedAt == snapshotDate,
            "metadata-only updates do not rebuild the asset reference snapshot"
        )
    }

    private static func testSnapshotSynchronizationFetchesOnlyAssetFileNames() throws {
        let source = try String(contentsOfFile: "Sources/PipelineHistoryStore.swift", encoding: .utf8)
        guard let start = source.range(of: "private func synchronizeAssetReferenceSnapshot()"),
              let end = source.range(
                of: "private func pipelineHistoryRequest()",
                range: start.upperBound..<source.endIndex
              ) else {
            throw RecoveryTestFailure("missing asset snapshot synchronization helpers")
        }
        let synchronization = String(source[start.lowerBound..<end.lowerBound])
        try expect(
            synchronization.contains("loadAssetReferenceFileNames()")
                && !synchronization.contains("let history = loadAllHistory()")
                && synchronization.contains("request.resultType = .dictionaryResultType")
                && synchronization.contains("request.propertiesToFetch = [\"audioFileName\", \"transcriptFileName\"]"),
            "snapshot synchronization fetches only asset filenames"
        )
    }

    private static func testSnapshotSynchronizationHasOneReferenceTrustGuard() throws {
        let source = try String(contentsOfFile: "Sources/PipelineHistoryStore.swift", encoding: .utf8)
        guard let start = source.range(of: "private func synchronizeAssetReferenceSnapshot()"),
              let end = source.range(
                of: "private func pipelineHistoryRequest()",
                range: start.upperBound..<source.endIndex
              ) else {
            throw RecoveryTestFailure("missing asset snapshot synchronization helpers")
        }
        let synchronization = String(source[start.lowerBound..<end.lowerBound])
        let guardCount = synchronization.components(
            separatedBy: "referenceTrust.permitsStartupReferenceCleanup"
        ).count - 1
        try expect(
            guardCount == 1,
            "asset snapshot synchronization checks reference trust once before fetching assets"
        )
    }

    private static func testApplicationSupportDirectoryHasDeterministicFallback() throws {
        let source = try String(contentsOfFile: "Sources/AppName.swift", encoding: .utf8)
        try expect(
            source.contains(".first ?? URL(fileURLWithPath: NSHomeDirectory())")
                && source.contains(".appendingPathComponent(\"Library/Application Support\", isDirectory: true)"),
            "Application Support lookup falls back without force-unwrapping"
        )
    }

    private static func testPublishedArchiveLowersReferenceTrust() throws {
        let fixture = try PersistentStoreFixture()
        defer { fixture.remove() }
        _ = PipelineHistoryStore(storeURL: fixture.storeURL)

        let archiveID = UUID(uuidString: "56B46A6B-8EF0-4BB6-AC13-5A4653133F1D")!
        let snapshotDirectory = fixture.directoryURL
            .appendingPathComponent("Recovery", isDirectory: true)
            .appendingPathComponent(
                "history-20250801T010323Z-\(archiveID.uuidString.lowercased())",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: snapshotDirectory.appendingPathComponent("payload", isDirectory: true),
            withIntermediateDirectories: true
        )
        let manifest = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": HistoryArchiveSnapshot.currentSchemaVersion,
            "id": archiveID.uuidString,
            "archivedAt": 1_754_010_203,
            "components": []
        ])
        try manifest.write(to: snapshotDirectory.appendingPathComponent("manifest.json"))

        let reopened = PipelineHistoryStore(storeURL: fixture.storeURL)
        try expect(
            reopened.referenceTrust == .recovered,
            "published archive blocks automatic cleanup for the active history"
        )
    }

    private static func testUnfinishedArchiveTransactionDisablesReferenceCleanup() throws {
        let fixture = try PersistentStoreFixture()
        defer { fixture.remove() }
        _ = PipelineHistoryStore(storeURL: fixture.storeURL)

        let transactionDirectory = fixture.directoryURL
            .appendingPathComponent("Recovery/.transactions", isDirectory: true)
        try FileManager.default.createDirectory(at: transactionDirectory, withIntermediateDirectories: true)
        try Data("incomplete archive journal".utf8).write(
            to: transactionDirectory.appendingPathComponent("unfinished.json")
        )

        let reopened = PipelineHistoryStore(storeURL: fixture.storeURL)
        try expect(
            reopened.referenceTrust == .unavailable,
            "unfinished archive transaction never permits automatic cleanup"
        )
    }

    private static func testArchivePreparationDetachesReadFailedStoreWithoutMutatingCanonicalFiles() throws {
        let fixture = try PersistentStoreFixture()
        defer { fixture.remove() }
        _ = PipelineHistoryStore(storeURL: fixture.storeURL)
        let originalBytes = try Data(contentsOf: fixture.storeURL)
        let store = PipelineHistoryStore(
            storeURL: fixture.storeURL,
            historyFetcher: { _, _ in
                throw RecoveryTestFailure("Injected read failure before archive preparation")
            }
        )
        _ = store.loadAllHistory()
        try expect(store.availability == .unavailable, "read failure enters protection mode")

        try store.detachForHistoryArchive()

        try expect(
            try Data(contentsOf: fixture.storeURL) == originalBytes,
            "archive preparation does not modify the canonical SQLite file"
        )
    }

    private static func testArchiveVerificationDetachesReadyStoreWithoutMutatingCanonicalFiles() throws {
        let fixture = try PersistentStoreFixture()
        defer { fixture.remove() }
        let store = PipelineHistoryStore(storeURL: fixture.storeURL)
        let originalBytes = try Data(contentsOf: fixture.storeURL)

        try store.detachForArchiveVerification()

        try expect(
            try Data(contentsOf: fixture.storeURL) == originalBytes,
            "archive verification detaches a ready store without rewriting canonical SQLite"
        )
    }

    private static func testUnavailableStorePreservesDatabaseComponentsAndRejectsMutations() throws {
        let fixture = try FailedStoreFixture()
        defer { fixture.remove() }
        let originalBytes = try fixture.componentURLs.map { try Data(contentsOf: $0) }
        var loadAttempts = 0
        let store = PipelineHistoryStore(
            storeURL: fixture.storeURL,
            persistentStoreLoader: { _ in
                loadAttempts += 1
                return RecoveryTestFailure("Injected persistent-store load failure")
            }
        )

        try expect(store.availability == .unavailable, "failed history store is unavailable")
        try expect(store.loadError != nil, "failed history retains diagnostic error")
        try expect(loadAttempts == 1, "failed history never retries the canonical store")
        try expect(
            store.referenceTrust == .unavailable,
            "unavailable history is not trusted for asset cleanup"
        )
        try expect(
            !FileManager.default.fileExists(atPath: fixture.recoveryRootURL.path),
            "unavailable history does not create a recovery replacement directory"
        )
        for (index, componentURL) in fixture.componentURLs.enumerated() {
            try expect(
                try Data(contentsOf: componentURL) == originalBytes[index],
                "unavailable history preserves component \(componentURL.lastPathComponent)"
            )
        }

        let item = makeHistoryItem()
        try expectStoreUnavailable("append") {
            _ = try store.append(item, maxCount: 10)
        }
        try expectStoreUnavailable("upsert") {
            _ = try store.upsert(item, maxCount: 10)
        }
        try expectStoreUnavailable("update") {
            try store.update(item)
        }
        try expectStoreUnavailable("delete") {
            _ = try store.delete(id: item.id)
        }
        try expectStoreUnavailable("clear") {
            _ = try store.clearAll()
        }
        try expectStoreUnavailable("trim") {
            _ = try store.trim(to: 10)
        }
    }

    private static func testReadFailureEntersProtectionMode() throws {
        let fixture = try PersistentStoreFixture()
        defer { fixture.remove() }
        var fetchAttempts = 0
        let store = PipelineHistoryStore(
            storeURL: fixture.storeURL,
            historyFetcher: { _, _ in
                fetchAttempts += 1
                throw RecoveryTestFailure("Injected history read failure")
            }
        )

        try expect(store.availability == .ready, "read failure is deferred until history access")
        try expect(store.loadAllHistory().isEmpty, "failed history reads have no usable entries")
        try expect(fetchAttempts == 1, "history read is attempted once")
        try expect(store.availability == .unavailable, "read failure enters protection mode")
        try expect(store.loadError != nil, "read failure retains diagnostic error")
        try expect(
            store.referenceTrust == .unavailable,
            "read failure never trusts history asset references"
        )
        _ = store.loadAllHistory()
        try expect(fetchAttempts == 1, "unavailable history does not retry reads during the launch")
        try expectStoreUnavailable("read-failed upsert") {
            _ = try store.upsert(makeHistoryItem(), maxCount: 10)
        }
    }

    private static func testReadabilityProbeUsesBoundedFetch() throws {
        let fixture = try PersistentStoreFixture()
        defer { fixture.remove() }
        var fetchLimit: Int?
        let store = PipelineHistoryStore(
            storeURL: fixture.storeURL,
            historyFetcher: { _, request in
                fetchLimit = request.fetchLimit
                return []
            }
        )

        try expect(store.verifyHistoryReadable(), "readability probe accepts a readable history")
        try expect(fetchLimit == 1, "readability probe fetches at most one history entry")
    }

    private static func testClearAllPropagatesReadFailure() throws {
        let fixture = try PersistentStoreFixture()
        defer { fixture.remove() }
        let store = PipelineHistoryStore(
            storeURL: fixture.storeURL,
            historyFetcher: { _, _ in
                throw RecoveryTestFailure("Injected clear-history read failure")
            }
        )

        do {
            _ = try store.clearAll()
        } catch is RecoveryTestFailure {
            return
        }
        throw RecoveryTestFailure("clearAll must not report a failed read as an empty deletion")
    }

    private static func testTrimPropagatesReadFailure() throws {
        let fixture = try PersistentStoreFixture()
        defer { fixture.remove() }
        let store = PipelineHistoryStore(
            storeURL: fixture.storeURL,
            historyFetcher: { _, _ in
                throw RecoveryTestFailure("Injected trim read failure")
            }
        )

        do {
            _ = try store.trim(to: 1)
        } catch is RecoveryTestFailure {
            return
        }
        throw RecoveryTestFailure("trim must not report a failed read as an empty deletion")
    }

    private static func testHealthyHistoryIsRetriedOnNextLaunch() throws {
        let fixture = try PersistentStoreFixture()
        defer { fixture.remove() }
        _ = PipelineHistoryStore(storeURL: fixture.storeURL)

        let unavailable = PipelineHistoryStore(
            storeURL: fixture.storeURL,
            persistentStoreLoader: { _ in
                RecoveryTestFailure("Injected one-launch load failure")
            }
        )
        try expect(
            unavailable.availability == .unavailable,
            "one failed launch enters protection mode"
        )

        let reopened = PipelineHistoryStore(storeURL: fixture.storeURL)
        try expect(
            reopened.availability == .ready,
            "later launches retry the unchanged canonical history"
        )
        try expect(
            reopened.durability == .durable,
            "later healthy launch remains durable"
        )
    }

    private static func testExplicitInMemoryStoreRejectsDurableWrites() throws {
        let store = PipelineHistoryStore(inMemory: true)
        try expect(store.availability == .ready, "explicit in-memory test store is ready")
        try expect(store.durability == .inMemory, "explicit in-memory store is distinct")
        try expect(
            store.referenceTrust == .unavailable,
            "explicit in-memory history is not trusted for asset cleanup"
        )

        do {
            _ = try store.upsert(makeHistoryItem(), maxCount: 10, requiresDurableStore: true)
            throw RecoveryTestFailure("Explicit in-memory stores must reject durable writes")
        } catch PipelineHistoryStoreError.durableStoreUnavailable {
            // expected
        }
    }

    // #840: a second append of an ID made a second row, so by-ID reads and
    // writes picked either one. It now saves over the row, as upsert does,
    // and a note in Recently Deleted stays there.
    private static func testAppendingAnIDTheStoreHoldsSavesOverThatRow() throws {
        let fixture = try PersistentStoreFixture()
        defer { fixture.remove() }
        let store = PipelineHistoryStore(storeURL: fixture.storeURL)
        let item = makeHistoryItem()
        _ = try store.append(item, maxCount: 10)
        let deletedAt = Date(timeIntervalSince1970: 2_000)
        try store.setDeletedAt(deletedAt, id: item.id)

        var changes: [PipelineHistoryChange] = []
        store.onChange = { changes += $0 }
        let edited = PipelineHistoryItem(
            id: item.id,
            timestamp: item.timestamp,
            rawTranscript: "Edited history item.",
            postProcessedTranscript: "Edited history item.",
            postProcessingPrompt: nil,
            contextSummary: "",
            contextScreenshotDataURL: nil,
            contextScreenshotStatus: "No screenshot",
            postProcessingStatus: "succeeded",
            debugStatus: "",
            customVocabulary: "",
            usedPostProcessing: false
        )
        _ = try store.append(edited, maxCount: 10)

        let history = store.loadAllHistory()
        try expect(history.map(\.id) == [item.id], "a second append of the same ID keeps one row")
        try expect(history.first?.deletedAt == deletedAt, "the note stays in Recently Deleted")
        try expect(history.first?.rawTranscript == "Edited history item.", "the second append saved over the row")
        try expect(changes.contains(.saved(item.id)), "sync hears about the saved note")
        try store.detachForArchiveVerification()
    }

    private static func makeHistoryItem() -> PipelineHistoryItem {
        PipelineHistoryItem(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_000),
            rawTranscript: "History item.",
            postProcessedTranscript: "History item.",
            postProcessingPrompt: nil,
            contextSummary: "",
            contextScreenshotDataURL: nil,
            contextScreenshotStatus: "No screenshot",
            postProcessingStatus: "succeeded",
            debugStatus: "",
            customVocabulary: "",
            usedPostProcessing: false
        )
    }

    private static func expectStoreUnavailable(
        _ operation: String,
        _ body: () throws -> Void
    ) throws {
        do {
            try body()
            throw RecoveryTestFailure("Unavailable history unexpectedly allowed \(operation)")
        } catch PipelineHistoryStoreError.storeUnavailable {
            // expected
        }
    }

    private static func expect(
        _ condition: @autoclosure () throws -> Bool,
        _ label: String
    ) throws {
        guard try condition() else { throw RecoveryTestFailure(label) }
    }
}

private class PersistentStoreFixture {
    let directoryURL: URL
    let storeURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        storeURL = directoryURL.appendingPathComponent("PipelineHistory.sqlite")
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

private final class FailedStoreFixture: PersistentStoreFixture {
    var recoveryRootURL: URL {
        directoryURL.appendingPathComponent("History Recovery", isDirectory: true)
    }

    var componentURLs: [URL] {
        [
            storeURL,
            URL(fileURLWithPath: storeURL.path + "-wal"),
            URL(fileURLWithPath: storeURL.path + "-shm")
        ]
    }

    override init() throws {
        try super.init()
        for (index, componentURL) in componentURLs.enumerated() {
            try Data("component-\(index)".utf8).write(to: componentURL)
        }
    }
}

private struct RecoveryTestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
