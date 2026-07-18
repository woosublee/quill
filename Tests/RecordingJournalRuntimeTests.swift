import AVFoundation
import Foundation

@main
struct RecordingJournalRuntimeTests {
    static func main() {
        do {
            try createBuildsSingleSourceInflightLayout()
            try duplicateCreateReusesExistingRecordingWithoutTruncation()
            try conflictingCreatePreservesExistingArtifact()
            try failedCreateRemovesNewInflightDirectory()
            try failedReplacementLeavesPreviousManifestReadable()
            try checkpointRejectsOverflowingGenerationWithoutTrapping()
            try writerCheckpointsOrderedPCMWithoutPerAppendManifestWrites()
            try writerRejectsOddChunksAndPostCloseWritesWithoutDamagingPCM()
            try writerCanBeReleasedAfterQueuedWriteWithoutCrashing()
            try finalizerRepairsHeaderTruncatesOddTailAndPromotesWithoutCopy()
            try finalizerUsesCommittedCheckpointBoundary()
            try finalizerRejectsTruncatedCommittedPayload()
            try finalizerPreservesEmptyAndConflictingArtifacts()
            try scannerPreservesManualRecoveryArtifactsAndUsesActualEvenPayload()
            try manualRecoveryCandidateProtectsDerivedPermanentFileName()
            try scannerReturnsExecutablePlanForRecordingState()
            try scannerPlansReuseAfterPromotionRenameBeforeManifestUpdate()
            try scannerRequiresPermanentArtifactForPromotedState()
            try scannerPlansPersistFinalizeAndCleanupAfterValidPromotion()
            try scannerIsReadOnlyAndIdempotent()
            print("RecordingJournalRuntimeTests passed")
        } catch {
            fputs("RecordingJournalRuntimeTests failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func createBuildsSingleSourceInflightLayout() throws {
        try withFixture { fixture in
            let session = try fixture.store.createSingleSource(fixture.request)
            let expectedDirectory = fixture.audioDirectory
                .appendingPathComponent("inflight", isDirectory: true)
                .appendingPathComponent(fixture.recordingID.uuidString.lowercased(), isDirectory: true)

            try expectEqual(session.recordingDirectory, expectedDirectory, "recording directory")
            try expectEqual(session.sourceURL.lastPathComponent, "microphone.wav.part", "source filename")
            try expectEqual(session.manifestURL.lastPathComponent, "manifest.json", "manifest filename")
            guard FileManager.default.fileExists(atPath: session.sourceURL.path),
                  FileManager.default.fileExists(atPath: session.manifestURL.path) else {
                throw TestFailure("source and manifest should exist after creation")
            }

            let sourceData = try Data(contentsOf: session.sourceURL)
            try expectEqual(sourceData.count, RecordingCanonicalWAV.headerByteCount, "empty source size")
            try expectEqual(RecordingCanonicalWAV.dataByteCount(in: sourceData), 0, "empty WAV data size")
            let manifest = try fixture.store.loadManifest(recordingID: fixture.recordingID)
            try expectEqual(manifest.generation, 1, "initial generation")
            try expectEqual(manifest.state, .recording, "initial state")
            try expectEqual(manifest.sources[0].committedDataByteCount, 0, "initial committed bytes")
        }
    }

    private static func duplicateCreateReusesExistingRecordingWithoutTruncation() throws {
        try withFixture { fixture in
            let first = try fixture.store.createSingleSource(fixture.request)
            try appendRaw(Data([0x01, 0x02, 0x03, 0x04]), to: first.sourceURL)
            let sizeBefore = try fileSize(first.sourceURL)

            let second = try fixture.store.createSingleSource(fixture.request)
            try expectEqual(second, first, "duplicate session")
            try expectEqual(try fileSize(second.sourceURL), sizeBefore, "duplicate create source size")
        }
    }

    private static func conflictingCreatePreservesExistingArtifact() throws {
        try withFixture { fixture in
            let session = try fixture.store.createSingleSource(fixture.request)
            try appendRaw(Data([0x01, 0x02]), to: session.sourceURL)
            let manifestBefore = try Data(contentsOf: session.manifestURL)
            let sourceBefore = try Data(contentsOf: session.sourceURL)

            var conflict = fixture.request
            conflict.monotonicAnchorNanoseconds += 1
            do {
                _ = try fixture.store.createSingleSource(conflict)
                throw TestFailure("conflicting create should fail")
            } catch RecordingJournalStoreError.conflictingExistingRecording {
                // expected
            }

            try expectEqual(try Data(contentsOf: session.manifestURL), manifestBefore, "conflict manifest preservation")
            try expectEqual(try Data(contentsOf: session.sourceURL), sourceBefore, "conflict source preservation")
        }
    }

    private static func failedCreateRemovesNewInflightDirectory() throws {
        try withFixture { fixture in
            var invalidRequest = fixture.request
            invalidRequest.sourceFileName = String(repeating: "a", count: 300)

            do {
                _ = try fixture.store.createSingleSource(invalidRequest)
                throw TestFailure("oversized source filename must fail creation")
            } catch {
                // expected
            }

            guard !FileManager.default.fileExists(
                atPath: fixture.store.recordingDirectory(
                    recordingID: fixture.recordingID
                ).path
            ) else {
                throw TestFailure("failed create must remove the new inflight directory")
            }
        }
    }

    private static func failedReplacementLeavesPreviousManifestReadable() throws {
        try withFixture { fixture in
            let session = try fixture.store.createSingleSource(fixture.request)
            let manifestBefore = try Data(contentsOf: session.manifestURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o500],
                ofItemAtPath: session.recordingDirectory.path
            )
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: session.recordingDirectory.path
                )
            }

            do {
                _ = try fixture.store.transition(
                    recordingID: fixture.recordingID,
                    to: .stopping
                )
                throw TestFailure("read-only directory should reject manifest replacement")
            } catch {
                // expected
            }

            try expectEqual(try Data(contentsOf: session.manifestURL), manifestBefore, "previous manifest after failed replace")
            let decoded = try fixture.store.loadManifest(recordingID: fixture.recordingID)
            try expectEqual(decoded.state, .recording, "state after failed replace")
        }
    }

    private static func checkpointRejectsOverflowingGenerationWithoutTrapping() throws {
        try withFixture { fixture in
            let session = try fixture.store.createSingleSource(fixture.request)
            var manifest = try fixture.store.loadManifest(recordingID: fixture.recordingID)
            manifest.generation = UInt64.max
            let encoded = try RecordingJournalCoding.makeEncoder().encode(manifest)
            try encoded.write(to: session.manifestURL, options: .atomic)

            do {
                _ = try fixture.store.recordCheckpoint(
                    recordingID: fixture.recordingID,
                    sourceID: fixture.sourceID,
                    commit: RecordingJournalSourceCommit(
                        dataByteCount: 2,
                        frameCount: 1,
                        firstCommittedFrameOffset: 0
                    )
                )
                throw TestFailure("overflowing checkpoint generation must fail")
            } catch RecordingJournalError.invalidManifest {
                // expected
            }
        }
    }

    private static func writerCheckpointsOrderedPCMWithoutPerAppendManifestWrites() throws {
        try withFixture { fixture in
            let session = try fixture.store.createSingleSource(fixture.request)
            let writer = try RecordingPCMJournalWriter(session: session, store: fixture.store)
            writer.enqueue(Data([0x01, 0x00, 0x02, 0x00]))
            writer.enqueue(Data([0x03, 0x00, 0x04, 0x00]))

            let beforeCheckpoint = try fixture.store.loadManifest(recordingID: fixture.recordingID)
            try expectEqual(beforeCheckpoint.generation, 1, "generation before checkpoint")
            try expectEqual(beforeCheckpoint.sources[0].committedDataByteCount, 0, "bytes before checkpoint")

            let firstCommit = try writer.checkpoint()
            try expectEqual(firstCommit.dataByteCount, 8, "checkpoint bytes")
            try expectEqual(firstCommit.frameCount, 4, "checkpoint frames")
            try expectEqual(firstCommit.firstCommittedFrameOffset, 0, "first frame offset")

            let payload = try payloadData(from: session.sourceURL)
            try expectEqual(payload, Data([0x01, 0x00, 0x02, 0x00, 0x03, 0x00, 0x04, 0x00]), "append order")
            let afterCheckpoint = try fixture.store.loadManifest(recordingID: fixture.recordingID)
            try expectEqual(afterCheckpoint.generation, 2, "generation after checkpoint")
            try expectEqual(afterCheckpoint.sources[0].committedDataByteCount, 8, "manifest checkpoint bytes")

            let unchanged = try writer.checkpoint()
            try expectEqual(unchanged, firstCommit, "unchanged checkpoint commit")
            try expectEqual(
                try fixture.store.loadManifest(recordingID: fixture.recordingID).generation,
                2,
                "unchanged checkpoint generation"
            )

            writer.enqueue(Data([0x05, 0x00]))
            let closedCommit = try writer.drainAndClose()
            try expectEqual(closedCommit.dataByteCount, 10, "closed commit bytes")
            try expectEqual(
                try fixture.store.loadManifest(recordingID: fixture.recordingID).sources[0].committedFrameCount,
                5,
                "closed manifest frames"
            )
        }
    }

    private static func writerRejectsOddChunksAndPostCloseWritesWithoutDamagingPCM() throws {
        try withFixture { fixture in
            let session = try fixture.store.createSingleSource(fixture.request)
            let writer = try RecordingPCMJournalWriter(session: session, store: fixture.store)
            writer.enqueue(Data([0x01, 0x00]))
            _ = try writer.checkpoint()
            let validPayload = try payloadData(from: session.sourceURL)

            writer.enqueue(Data([0xFF]))
            do {
                _ = try writer.checkpoint()
                throw TestFailure("odd PCM chunk should fail")
            } catch RecordingPCMJournalWriterError.oddByteChunk {
                // expected
            }
            try expectEqual(try payloadData(from: session.sourceURL), validPayload, "payload after odd chunk")
        }

        try withFixture { fixture in
            let session = try fixture.store.createSingleSource(fixture.request)
            let writer = try RecordingPCMJournalWriter(session: session, store: fixture.store)
            writer.enqueue(Data([0x01, 0x00]))
            _ = try writer.drainAndClose()
            let payloadBefore = try payloadData(from: session.sourceURL)
            writer.enqueue(Data([0x02, 0x00]))
            do {
                _ = try writer.checkpoint()
                throw TestFailure("post-close enqueue should fail")
            } catch RecordingPCMJournalWriterError.writerClosed {
                // expected
            }
            try expectEqual(try payloadData(from: session.sourceURL), payloadBefore, "payload after close")
        }
    }

    private static func writerCanBeReleasedAfterQueuedWriteWithoutCrashing() throws {
        try withFixture { fixture in
            let session = try fixture.store.createSingleSource(fixture.request)
            var writer: RecordingPCMJournalWriter? = try RecordingPCMJournalWriter(
                session: session,
                store: fixture.store
            )
            writer?.enqueue(Data([0x01, 0x00]))
            writer = nil

            let deadline = Date().addingTimeInterval(2)
            while try fileSize(session.sourceURL) == UInt64(RecordingCanonicalWAV.headerByteCount),
                  Date() < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            try expectEqual(
                try payloadData(from: session.sourceURL),
                Data([0x01, 0x00]),
                "queued write before writer release"
            )
        }
    }

    private static func finalizerRepairsHeaderTruncatesOddTailAndPromotesWithoutCopy() throws {
        try withFixture { fixture in
            let session = try fixture.store.createSingleSource(fixture.request)
            let writer = try RecordingPCMJournalWriter(session: session, store: fixture.store)
            writer.enqueue(Data([0x01, 0x00, 0x02, 0x00]))
            _ = try writer.drainAndClose()
            try overwriteHeader(with: Data(repeating: 0xA5, count: RecordingCanonicalWAV.headerByteCount), at: session.sourceURL)
            try appendRaw(Data([0x7F]), to: session.sourceURL)
            _ = try fixture.store.transition(recordingID: fixture.recordingID, to: .stopping)

            let inodeBefore = try inodeNumber(session.sourceURL)
            let finalizer = RecordingArtifactFinalizer(store: fixture.store)
            let artifact = try finalizer.finalizeSingleSource(recordingID: fixture.recordingID)
            try expectEqual(artifact.dataByteCount, 4, "finalized bytes")
            try expectEqual(artifact.frameCount, 2, "finalized frames")
            guard artifact.removedTrailingData else {
                throw TestFailure("finalizer should report odd-tail truncation")
            }

            let sourceData = try Data(contentsOf: session.sourceURL)
            try expectEqual(RecordingCanonicalWAV.dataByteCount(in: sourceData), 4, "patched header data size")
            try expectEqual(sourceData.count, RecordingCanonicalWAV.headerByteCount + 4, "truncated source size")

            let readable = try AVAudioFile(forReading: session.sourceURL)
            try expectEqual(readable.fileFormat.sampleRate, 16_000, "finalized sample rate")
            try expectEqual(readable.fileFormat.channelCount, 1, "finalized channel count")
            try expectEqual(readable.length, 2, "finalized frame count")

            let promotion = try finalizer.promote(artifact)
            let permanentURL = fixture.audioDirectory.appendingPathComponent(promotion.fileName)
            try expectEqual(try inodeNumber(permanentURL), inodeBefore, "promotion inode identity")
            try expectEqual(promotion.dataByteCount, 4, "promotion bytes")
            try expectEqual(try finalizer.promote(artifact), promotion, "repeated promotion")
        }
    }

    private static func finalizerUsesCommittedCheckpointBoundary() throws {
        try withFixture { fixture in
            let session = try fixture.store.createSingleSource(fixture.request)
            let writer = try RecordingPCMJournalWriter(session: session, store: fixture.store)
            writer.enqueue(Data([0x01, 0x00, 0x02, 0x00]))
            _ = try writer.checkpoint()
            try appendRaw(Data([0x03, 0x00, 0x04, 0x00]), to: session.sourceURL)
            _ = try fixture.store.transition(recordingID: fixture.recordingID, to: .recoverable)

            let artifact = try RecordingArtifactFinalizer(store: fixture.store)
                .finalizeSingleSource(recordingID: fixture.recordingID)

            try expectEqual(artifact.dataByteCount, 4, "committed finalization bytes")
            try expectEqual(
                try payloadData(from: session.sourceURL),
                Data([0x01, 0x00, 0x02, 0x00]),
                "uncommitted tail truncation"
            )
        }
    }

    private static func finalizerRejectsTruncatedCommittedPayload() throws {
        try withFixture { fixture in
            let session = try fixture.store.createSingleSource(fixture.request)
            let writer = try RecordingPCMJournalWriter(session: session, store: fixture.store)
            writer.enqueue(Data([0x01, 0x00, 0x02, 0x00]))
            _ = try writer.checkpoint()
            let handle = try FileHandle(forUpdating: session.sourceURL)
            try handle.truncate(
                atOffset: UInt64(RecordingCanonicalWAV.headerByteCount + 2)
            )
            try handle.close()
            _ = try fixture.store.transition(recordingID: fixture.recordingID, to: .recoverable)

            do {
                _ = try RecordingArtifactFinalizer(store: fixture.store)
                    .finalizeSingleSource(recordingID: fixture.recordingID)
                throw TestFailure("truncated committed payload must fail")
            } catch RecordingArtifactFinalizerError.committedPayloadUnavailable {
                // expected
            }
        }
    }

    private static func finalizerPreservesEmptyAndConflictingArtifacts() throws {
        try withFixture { fixture in
            let session = try fixture.store.createSingleSource(fixture.request)
            _ = try fixture.store.transition(recordingID: fixture.recordingID, to: .stopping)
            do {
                _ = try RecordingArtifactFinalizer(store: fixture.store)
                    .finalizeSingleSource(recordingID: fixture.recordingID)
                throw TestFailure("empty source should not finalize")
            } catch RecordingArtifactFinalizerError.emptyPayload {
                // expected
            }
            guard FileManager.default.fileExists(atPath: session.sourceURL.path) else {
                throw TestFailure("empty source should be preserved")
            }
        }

        try withFixture { fixture in
            let session = try fixture.store.createSingleSource(fixture.request)
            let writer = try RecordingPCMJournalWriter(session: session, store: fixture.store)
            writer.enqueue(Data([0x01, 0x00]))
            _ = try writer.drainAndClose()
            _ = try fixture.store.transition(recordingID: fixture.recordingID, to: .stopping)
            let finalizer = RecordingArtifactFinalizer(store: fixture.store)
            let artifact = try finalizer.finalizeSingleSource(recordingID: fixture.recordingID)
            let permanentURL = fixture.audioDirectory
                .appendingPathComponent(fixture.recordingID.uuidString.lowercased() + ".wav")
            try Data(repeating: 0xCC, count: 80).write(to: permanentURL)
            let sourceBefore = try Data(contentsOf: session.sourceURL)
            let permanentBefore = try Data(contentsOf: permanentURL)

            do {
                _ = try finalizer.promote(artifact)
                throw TestFailure("conflicting destination should fail")
            } catch RecordingArtifactFinalizerError.promotionConflict {
                // expected
            }
            try expectEqual(try Data(contentsOf: session.sourceURL), sourceBefore, "source conflict preservation")
            try expectEqual(try Data(contentsOf: permanentURL), permanentBefore, "destination conflict preservation")
        }
    }

    private static func scannerPreservesManualRecoveryArtifactsAndUsesActualEvenPayload() throws {
        try withFixture { fixture in
            let missingManifestDirectory = fixture.audioDirectory
                .appendingPathComponent("inflight", isDirectory: true)
                .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
            try FileManager.default.createDirectory(at: missingManifestDirectory, withIntermediateDirectories: true)
            let orphan = missingManifestDirectory.appendingPathComponent("microphone.wav.part")
            try Data([0xAA, 0xBB]).write(to: orphan)

            let corruptDirectory = fixture.audioDirectory
                .appendingPathComponent("inflight", isDirectory: true)
                .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
            try FileManager.default.createDirectory(at: corruptDirectory, withIntermediateDirectories: true)
            try Data("not-json".utf8).write(to: corruptDirectory.appendingPathComponent("manifest.json"))

            let valid = try fixture.store.createSingleSource(fixture.request)
            let validWriter = try RecordingPCMJournalWriter(
                session: valid,
                store: fixture.store
            )
            validWriter.enqueue(Data([0x01, 0x00, 0x02, 0x00]))
            _ = try validWriter.checkpoint()
            try appendRaw(Data([0xFF]), to: valid.sourceURL)
            let scanner = InflightRecordingRecovery(store: fixture.store)
            let before = try snapshotTree(fixture.audioDirectory)
            let candidates = scanner.scan()
            let after = try snapshotTree(fixture.audioDirectory)

            try expectEqual(after, before, "scanner filesystem preservation")
            guard candidates.filter({ $0.action == .manualRecoveryRequired }).count == 2 else {
                throw TestFailure("missing and corrupt manifests should require manual recovery: \(candidates)")
            }
            guard let validCandidate = candidates.first(where: { $0.recordingID == fixture.recordingID }) else {
                throw TestFailure("missing valid recovery candidate")
            }
            try expectEqual(validCandidate.action, .markRecoverable, "valid candidate action")
            try expectEqual(validCandidate.recoverableDataByteCount, 4, "actual even payload")
            guard validCandidate.diagnostics.contains(.oddTrailingByte) else {
                throw TestFailure("expected odd-tail diagnostic: \(validCandidate.diagnostics)")
            }
        }
    }

    private static func manualRecoveryCandidateProtectsDerivedPermanentFileName() throws {
        try withFixture { fixture in
            let directory = fixture.store.recordingDirectory(recordingID: fixture.recordingID)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )

            guard let candidate = InflightRecordingRecovery(store: fixture.store)
                .scan()
                .first(where: { $0.recordingID == fixture.recordingID }) else {
                throw TestFailure("missing manual recovery candidate")
            }

            try expectEqual(
                candidate.protectedPermanentFileName,
                fixture.recordingID.uuidString.lowercased() + ".wav",
                "manual recovery permanent filename protection"
            )
        }
    }

    private static func scannerReturnsExecutablePlanForRecordingState() throws {
        try withFixture { fixture in
            let session = try fixture.store.createSingleSource(fixture.request)
            let writer = try RecordingPCMJournalWriter(session: session, store: fixture.store)
            writer.enqueue(Data([0x01, 0x00]))
            _ = try writer.checkpoint()
            let scanner = InflightRecordingRecovery(store: fixture.store)
            let candidate = scanner.scan().first(where: { $0.recordingID == fixture.recordingID })
            try expectEqual(candidate?.action, .markRecoverable, "recording-state scan action")

            _ = try fixture.store.transition(recordingID: fixture.recordingID, to: .recoverable)
            let artifact = try RecordingArtifactFinalizer(store: fixture.store)
                .finalizeSingleSource(recordingID: fixture.recordingID)
            try expectEqual(artifact.dataByteCount, 2, "recording-state planned finalization")
        }
    }

    private static func scannerPlansReuseAfterPromotionRenameBeforeManifestUpdate() throws {
        try withFixture { fixture in
            let session = try fixture.store.createSingleSource(fixture.request)
            let writer = try RecordingPCMJournalWriter(session: session, store: fixture.store)
            writer.enqueue(Data([0x01, 0x00, 0x02, 0x00]))
            _ = try writer.drainAndClose()
            _ = try fixture.store.transition(recordingID: fixture.recordingID, to: .stopping)
            let finalizer = RecordingArtifactFinalizer(store: fixture.store)
            let artifact = try finalizer.finalizeSingleSource(recordingID: fixture.recordingID)
            let promotion = try finalizer.promote(artifact)

            let candidate = InflightRecordingRecovery(store: fixture.store)
                .scan()
                .first(where: { $0.recordingID == fixture.recordingID })
            try expectEqual(candidate?.action, .reusePromotedArtifact, "rename crash-window action")
            try expectEqual(candidate?.promotion, promotion, "rename crash-window promotion")
        }
    }

    private static func scannerRequiresPermanentArtifactForPromotedState() throws {
        try withFixture { fixture in
            let session = try fixture.store.createSingleSource(fixture.request)
            let writer = try RecordingPCMJournalWriter(session: session, store: fixture.store)
            writer.enqueue(Data([0x01, 0x00, 0x02, 0x00]))
            _ = try writer.drainAndClose()
            _ = try fixture.store.transition(recordingID: fixture.recordingID, to: .stopping)
            let artifact = try RecordingArtifactFinalizer(store: fixture.store)
                .finalizeSingleSource(recordingID: fixture.recordingID)
            let declaredPromotion = RecordingPromotion(
                fileName: fixture.recordingID.uuidString.lowercased() + ".wav",
                dataByteCount: artifact.dataByteCount,
                frameCount: artifact.frameCount
            )
            _ = try fixture.store.transition(
                recordingID: fixture.recordingID,
                to: .promoted,
                promotion: declaredPromotion
            )

            guard let candidate = InflightRecordingRecovery(store: fixture.store)
                .scan()
                .first(where: { $0.recordingID == fixture.recordingID }) else {
                throw TestFailure("missing promoted-state candidate")
            }
            try expectEqual(candidate.action, .manualRecoveryRequired, "missing permanent promotion action")
            guard candidate.diagnostics.contains(.missingPermanentArtifact) else {
                throw TestFailure("missing permanent WAV should be diagnosed: \(candidate.diagnostics)")
            }
            guard FileManager.default.fileExists(atPath: session.sourceURL.path) else {
                throw TestFailure("scanner should preserve the source when permanent WAV is missing")
            }
        }
    }

    private static func scannerPlansPersistFinalizeAndCleanupAfterValidPromotion() throws {
        try withFixture { fixture in
            let session = try fixture.store.createSingleSource(fixture.request)
            let writer = try RecordingPCMJournalWriter(session: session, store: fixture.store)
            writer.enqueue(Data([0x01, 0x00, 0x02, 0x00]))
            _ = try writer.drainAndClose()
            _ = try fixture.store.transition(recordingID: fixture.recordingID, to: .stopping)
            let finalizer = RecordingArtifactFinalizer(store: fixture.store)
            let artifact = try finalizer.finalizeSingleSource(recordingID: fixture.recordingID)
            let promotion = try finalizer.promote(artifact)
            _ = try fixture.store.transition(
                recordingID: fixture.recordingID,
                to: .promoted,
                promotion: promotion
            )

            let scanner = InflightRecordingRecovery(store: fixture.store)
            try expectEqual(
                scanner.scan().first(where: { $0.recordingID == fixture.recordingID })?.action,
                .persistHistory,
                "promoted action"
            )
            _ = try fixture.store.transition(
                recordingID: fixture.recordingID,
                to: .historyStored,
                historyItemID: fixture.recordingID
            )
            try expectEqual(
                scanner.scan().first(where: { $0.recordingID == fixture.recordingID })?.action,
                .markFinalized,
                "history stored action"
            )
            _ = try fixture.store.transition(recordingID: fixture.recordingID, to: .finalized)
            try expectEqual(
                scanner.scan().first(where: { $0.recordingID == fixture.recordingID })?.action,
                .cleanupEligible,
                "finalized action"
            )
        }
    }

    private static func scannerIsReadOnlyAndIdempotent() throws {
        try withFixture { fixture in
            let session = try fixture.store.createSingleSource(fixture.request)
            let writer = try RecordingPCMJournalWriter(session: session, store: fixture.store)
            writer.enqueue(Data([0x01, 0x00]))
            _ = try writer.checkpoint()
            let scanner = InflightRecordingRecovery(store: fixture.store)
            let before = try snapshotTree(fixture.audioDirectory)
            let first = scanner.scan()
            let middle = try snapshotTree(fixture.audioDirectory)
            let second = scanner.scan()
            let after = try snapshotTree(fixture.audioDirectory)

            try expectEqual(first, second, "repeated scan plans")
            try expectEqual(before, middle, "first scan preservation")
            try expectEqual(middle, after, "second scan preservation")
        }
    }

    private static func withFixture(_ body: (Fixture) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-recording-journal-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let recordingID = UUID()
        let sourceID = UUID()
        let segmentID = UUID()
        let audioDirectory = root.appendingPathComponent("audio", isDirectory: true)
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = RecordingJournalStore(audioDirectory: audioDirectory) {
            defer { now = now.addingTimeInterval(1) }
            return now
        }
        let request = RecordingJournalCreateRequest(
            recordingID: recordingID,
            sourceID: sourceID,
            segmentID: segmentID,
            startedAt: now,
            monotonicAnchorNanoseconds: 100,
            sourceMode: .microphone,
            sourceKind: .microphone,
            sourceFileName: "microphone.wav.part",
            pipeline: makePipelineSnapshot()
        )
        try body(Fixture(
            audioDirectory: audioDirectory,
            recordingID: recordingID,
            sourceID: sourceID,
            segmentID: segmentID,
            store: store,
            request: request
        ))
    }

    private static func makePipelineSnapshot() -> RecordingPipelineSnapshot {
        RecordingPipelineSnapshot(
            trigger: .toggle,
            intent: .dictation,
            selectedText: nil,
            title: nil,
            calendar: nil,
            transcription: RecordingTranscriptionSnapshot(
                backend: .apiStandard,
                modelID: "whisper-large-v3",
                spokenLanguageCode: "auto",
                providerSelection: .defaultConfiguration
            ),
            processing: RecordingProcessingSnapshot(
                postProcessingEnabled: false,
                preferredModelID: nil,
                fallbackModelID: nil,
                outputLanguage: "auto",
                preserveExactWording: false,
                contextCaptureEnabled: false,
                instructionExecutionGuardEnabled: true,
                customVocabulary: [],
                customSystemPrompt: nil
            )
        )
    }

    private static func appendRaw(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private static func overwriteHeader(with data: Data, at url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: data)
    }

    private static func payloadData(from url: URL) throws -> Data {
        let data = try Data(contentsOf: url)
        guard data.count >= RecordingCanonicalWAV.headerByteCount else {
            throw TestFailure("source is shorter than reserved WAV header")
        }
        return data.subdata(in: RecordingCanonicalWAV.headerByteCount..<data.count)
    }

    private static func fileSize(_ url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let number = attributes[.size] as? NSNumber else {
            throw TestFailure("missing file size for \(url.path)")
        }
        return number.uint64Value
    }

    private static func inodeNumber(_ url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let number = attributes[.systemFileNumber] as? NSNumber else {
            throw TestFailure("missing inode for \(url.path)")
        }
        return number.uint64Value
    }

    private static func snapshotTree(_ root: URL) throws -> [String: String] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [],
            errorHandler: nil
        ) else {
            return [:]
        }
        var result: [String: String] = [:]
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            let relative = String(url.path.dropFirst(root.path.count + 1))
            if values.isDirectory == true {
                result[relative] = "directory"
            } else {
                let data = try Data(contentsOf: url)
                result[relative] = "\(values.fileSize ?? 0):\(data.base64EncodedString())"
            }
        }
        return result
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

    private struct Fixture {
        let audioDirectory: URL
        let recordingID: UUID
        let sourceID: UUID
        let segmentID: UUID
        let store: RecordingJournalStore
        let request: RecordingJournalCreateRequest
    }

    private struct TestFailure: Error, CustomStringConvertible {
        let description: String

        init(_ description: String) {
            self.description = description
        }
    }
}
