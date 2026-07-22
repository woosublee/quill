import Foundation

@main
struct SegmentedRecordingJournalControllerTests {
    static func main() {
        do {
            try initialHandleMatchesRequestedSources()
            try switchingDrainsSegmentsAndPreservesRecordingOrder()
            try timestampOffsetsUseTheOriginalRecordingAnchor()
            try checkpointCommitsEveryActiveSourceInOneGeneration()
            try stopPreserveAndDiscardHaveStableLifecycleSemantics()
            try failedNextWriterLeavesEarlierAudioRecoverable()
            try manifestFailureTransitionIsAtomic()
            try recoverableFailureTransitionPersistsHealthyCommit()
            try manifestCheckpointFailureConvergesToTerminalCallback()
            try switchManifestFailureConvergesToTerminalCallback()
            try timerSyncFailureDoesNotAlsoReportDiagnosticFailure()
            try stopManifestFailureCanUseFailureClose()
            try terminalAppendFailureConvergesAndPreservesHealthySource()
            print("SegmentedRecordingJournalControllerTests passed")
        } catch {
            fputs("SegmentedRecordingJournalControllerTests failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func initialHandleMatchesRequestedSources() throws {
        try withFixture { fixture in
            let controller = try SegmentedRecordingJournalController(
                request: fixture.request(sources: [
                    RecordingJournalSegmentSourceRequest(
                        id: fixture.microphoneSourceID,
                        kind: .microphone
                    )
                ]),
                store: fixture.store
            )

            try expectEqual(controller.recordingID, fixture.recordingID, "recording ID")
            try expectEqual(controller.activeSegment.id, fixture.firstSegmentID, "segment ID")
            try expectEqual(controller.activeSegment.sequence, 0, "segment sequence")
            guard controller.activeSegment.microphoneSink != nil,
                  controller.activeSegment.systemAudioSink == nil else {
                throw TestFailure("microphone segment must expose only its microphone sink")
            }
        }
    }

    private static func switchingDrainsSegmentsAndPreservesRecordingOrder() throws {
        try withFixture { fixture in
            let controller = try SegmentedRecordingJournalController(
                request: fixture.request(sources: [
                    RecordingJournalSegmentSourceRequest(
                        id: fixture.microphoneSourceID,
                        kind: .microphone
                    )
                ]),
                store: fixture.store
            )
            controller.activeSegment.microphoneSink?.enqueue(Data([0x01, 0x00]))

            let combinedSegmentID = UUID()
            let combinedMicrophoneID = UUID()
            let combinedSystemAudioID = UUID()
            let combined = try controller.switchSegment(
                segmentID: combinedSegmentID,
                sources: [
                    RecordingJournalSegmentSourceRequest(
                        id: combinedMicrophoneID,
                        kind: .microphone
                    ),
                    RecordingJournalSegmentSourceRequest(
                        id: combinedSystemAudioID,
                        kind: .systemAudio
                    )
                ]
            )
            combined.microphoneSink?.enqueue(Data([0x02, 0x00]))
            combined.systemAudioSink?.enqueue(Data([0x03, 0x00]))

            let systemSegmentID = UUID()
            let systemSourceID = UUID()
            let system = try controller.switchSegment(
                segmentID: systemSegmentID,
                sources: [RecordingJournalSegmentSourceRequest(
                    id: systemSourceID,
                    kind: .systemAudio
                )]
            )
            system.systemAudioSink?.enqueue(Data([0x04, 0x00]))
            try controller.stopAndClose()

            let manifest = try fixture.store.loadManifest(recordingID: fixture.recordingID)
            try expectEqual(manifest.segments.map(\.sequence), [0, 1, 2], "segment order")
            try expectEqual(
                manifest.segments.map(\.id),
                [fixture.firstSegmentID, combinedSegmentID, systemSegmentID],
                "segment IDs"
            )
            try expectEqual(manifest.pipeline, fixture.pipeline, "stable pipeline snapshot")
            try expectEqual(
                manifest.sources.map(\.committedDataByteCount),
                [2, 2, 2, 2],
                "all segment commits"
            )
            try expectEqual(manifest.state, .stopping, "stopped manifest state")
        }
    }

    private static func timestampOffsetsUseTheOriginalRecordingAnchor() throws {
        try withFixture { fixture in
            let controller = try SegmentedRecordingJournalController(
                request: fixture.request(sources: [
                    RecordingJournalSegmentSourceRequest(
                        id: fixture.microphoneSourceID,
                        kind: .microphone
                    )
                ]),
                store: fixture.store
            )
            controller.activeSegment.microphoneSink?.enqueue(
                Data([0x01, 0x00]),
                firstFrameMonotonicNanoseconds: fixture.anchor + 100_000_000
            )
            let nextID = UUID()
            let next = try controller.switchSegment(
                segmentID: UUID(),
                sources: [RecordingJournalSegmentSourceRequest(
                    id: nextID,
                    kind: .systemAudio
                )]
            )
            next.systemAudioSink?.enqueue(
                Data([0x02, 0x00]),
                firstFrameMonotonicNanoseconds: fixture.anchor + 1_100_000_000
            )
            try controller.stopAndClose()

            let manifest = try fixture.store.loadManifest(recordingID: fixture.recordingID)
            try expectEqual(
                manifest.sources.first(where: { $0.id == fixture.microphoneSourceID })?
                    .firstCommittedFrameOffset,
                1_600,
                "first segment offset"
            )
            try expectEqual(
                manifest.sources.first(where: { $0.id == nextID })?
                    .firstCommittedFrameOffset,
                17_600,
                "switched segment offset"
            )
        }
    }

    private static func checkpointCommitsEveryActiveSourceInOneGeneration() throws {
        try withFixture { fixture in
            let controller = try SegmentedRecordingJournalController(
                request: fixture.request(sources: [
                    RecordingJournalSegmentSourceRequest(
                        id: fixture.microphoneSourceID,
                        kind: .microphone
                    ),
                    RecordingJournalSegmentSourceRequest(
                        id: fixture.systemAudioSourceID,
                        kind: .systemAudio
                    )
                ]),
                store: fixture.store
            )
            controller.activeSegment.microphoneSink?.enqueue(Data([0x01, 0x00]))
            controller.activeSegment.systemAudioSink?.enqueue(Data([0x02, 0x00]))

            try controller.checkpoint()

            let manifest = try fixture.store.loadManifest(recordingID: fixture.recordingID)
            try expectEqual(manifest.generation, 2, "batch checkpoint generation")
            try expectEqual(
                manifest.sources.map(\.committedDataByteCount),
                [2, 2],
                "batch checkpoint bytes"
            )
        }
    }

    private static func stopPreserveAndDiscardHaveStableLifecycleSemantics() throws {
        try withFixture { fixture in
            let stopped = try SegmentedRecordingJournalController(
                request: fixture.request(sources: [
                    RecordingJournalSegmentSourceRequest(
                        id: fixture.microphoneSourceID,
                        kind: .microphone
                    )
                ]),
                store: fixture.store
            )
            stopped.activeSegment.microphoneSink?.enqueue(Data([0x01, 0x00]))
            try stopped.stopAndClose()
            try stopped.stopAndClose()
            try expectEqual(
                try fixture.store.loadManifest(recordingID: fixture.recordingID).state,
                .stopping,
                "idempotent stop"
            )
            do {
                try stopped.discard()
                throw TestFailure("stopped controller must reject discard")
            } catch SegmentedRecordingJournalControllerError.controllerClosed {
                // expected
            }
        }

        try withFixture { fixture in
            let recoverable = try SegmentedRecordingJournalController(
                request: fixture.request(sources: [
                    RecordingJournalSegmentSourceRequest(
                        id: fixture.microphoneSourceID,
                        kind: .microphone
                    )
                ]),
                store: fixture.store
            )
            recoverable.activeSegment.microphoneSink?.enqueue(Data([0x01, 0x00]))
            try recoverable.preserveForRecovery()
            try recoverable.preserveForRecovery()
            try expectEqual(
                try fixture.store.loadManifest(recordingID: fixture.recordingID).state,
                .recoverable,
                "idempotent preserve"
            )
        }

        try withFixture { fixture in
            let discarded = try SegmentedRecordingJournalController(
                request: fixture.request(sources: [
                    RecordingJournalSegmentSourceRequest(
                        id: fixture.microphoneSourceID,
                        kind: .microphone
                    )
                ]),
                store: fixture.store
            )
            try discarded.discard()
            try discarded.discard()
            guard !FileManager.default.fileExists(
                atPath: fixture.store.recordingDirectory(
                    recordingID: fixture.recordingID
                ).path
            ) else {
                throw TestFailure("discard must remove the recording directory")
            }
        }
    }

    private static func failedNextWriterLeavesEarlierAudioRecoverable() throws {
        try withFixture { fixture in
            var writerCount = 0
            let controller = try SegmentedRecordingJournalController(
                request: fixture.request(sources: [
                    RecordingJournalSegmentSourceRequest(
                        id: fixture.microphoneSourceID,
                        kind: .microphone
                    )
                ]),
                store: fixture.store,
                makeWriter: { session, store in
                    writerCount += 1
                    if writerCount == 2 {
                        throw TestFailure("injected next-segment writer failure")
                    }
                    return try RecordingPCMJournalWriter(session: session, store: store)
                }
            )
            controller.activeSegment.microphoneSink?.enqueue(Data([0x01, 0x00]))

            do {
                _ = try controller.switchSegment(
                    segmentID: UUID(),
                    sources: [RecordingJournalSegmentSourceRequest(
                        id: UUID(),
                        kind: .systemAudio
                    )]
                )
                throw TestFailure("switch must surface writer construction failure")
            } catch let error as TestFailure
                where error.description == "injected next-segment writer failure" {
                // expected
            }

            try controller.stopAndClose()
            let manifest = try fixture.store.loadManifest(recordingID: fixture.recordingID)
            try expectEqual(manifest.state, .stopping, "failed switch stopped state")
            try expectEqual(manifest.segments.map(\.sequence), [0, 1], "empty next segment retained")
            try expectEqual(
                manifest.sources.map(\.committedDataByteCount),
                [2, 0],
                "earlier audio preserved after failed switch"
            )
        }
    }

    private static func manifestFailureTransitionIsAtomic() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "quill-segmented-manifest-failure-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var rejectInterruptedManifest = false
        let store = RecordingJournalStore(
            audioDirectory: root.appendingPathComponent("audio", isDirectory: true),
            manifestWriter: RecordingJournalManifestWriter(write: { data, generation, targetURL, fileManager in
                if rejectInterruptedManifest,
                   let manifest = try? RecordingJournalCoding.makeDecoder().decode(
                       RecordingJournalManifest.self,
                       from: data
                   ),
                   manifest.interruptionReason == .storageFull {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
                }
                try RecordingJournalManifestWriter.live.write(
                    data,
                    generation,
                    targetURL,
                    fileManager
                )
            })
        )
        let recordingID = UUID()
        let microphoneID = UUID()
        let systemID = UUID()
        let controller = try SegmentedRecordingJournalController(
            request: SegmentedRecordingJournalCreateRequest(
                recordingID: recordingID,
                segmentID: UUID(),
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                monotonicAnchorNanoseconds: 1_000_000_000,
                sources: [
                    RecordingJournalSegmentSourceRequest(id: microphoneID, kind: .microphone),
                    RecordingJournalSegmentSourceRequest(id: systemID, kind: .systemAudio)
                ],
                pipeline: makePipelineSnapshot()
            ),
            store: store
        )
        controller.activeSegment.microphoneSink?.enqueue(Data([0x01, 0x00]))
        controller.activeSegment.systemAudioSink?.enqueue(Data([0x02, 0x00]))
        try controller.checkpoint()
        let before = try Data(contentsOf: store.manifestURL(recordingID: recordingID))
        let beforeManifest = try store.loadManifest(recordingID: recordingID)
        rejectInterruptedManifest = true

        do {
            _ = try store.markRecoverableAfterPersistenceFailure(
                recordingID: recordingID,
                commitsBySourceID: [:],
                interruptionReason: .storageFull
            )
            throw TestFailure("interruption manifest write must fail")
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain {
            // expected
        }

        let after = try Data(contentsOf: store.manifestURL(recordingID: recordingID))
        let afterManifest = try store.loadManifest(recordingID: recordingID)
        try expectEqual(after, before, "failed manifest bytes")
        try expectEqual(afterManifest.generation, beforeManifest.generation, "failed generation")
        try expectEqual(afterManifest.state, .recording, "failed manifest state")
        try expectEqual(afterManifest.interruptionReason, nil, "failed manifest reason")
    }

    private static func recoverableFailureTransitionPersistsHealthyCommit() throws {
        try withFixture { fixture in
            let controller = try SegmentedRecordingJournalController(
                request: fixture.request(sources: [RecordingJournalSegmentSourceRequest(
                    id: fixture.microphoneSourceID,
                    kind: .microphone
                )]),
                store: fixture.store
            )
            controller.activeSegment.microphoneSink?.enqueue(Data([0x01, 0x00]))
            _ = try fixture.store.markRecoverableAfterPersistenceFailure(
                recordingID: fixture.recordingID,
                commitsBySourceID: [:],
                interruptionReason: .storageFull
            )
            let before = try fixture.store.loadManifest(recordingID: fixture.recordingID)

            let after = try fixture.store.markRecoverableAfterPersistenceFailure(
                recordingID: fixture.recordingID,
                commitsBySourceID: [fixture.microphoneSourceID: RecordingJournalSourceCommit(
                    dataByteCount: 2,
                    frameCount: 1,
                    firstCommittedFrameOffset: 0
                )],
                interruptionReason: .storageFull
            )

            try expectEqual(after.generation, before.generation + 1, "recoverable commit generation")
            try expectEqual(
                after.sources[0].committedDataByteCount,
                2,
                "recoverable healthy commit bytes"
            )
        }
    }

    private static func manifestCheckpointFailureConvergesToTerminalCallback() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "quill-segmented-checkpoint-failure-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let failManifestWrites = LockedFlag()
        let store = RecordingJournalStore(
            audioDirectory: root.appendingPathComponent("audio", isDirectory: true),
            manifestWriter: RecordingJournalManifestWriter(write: { data, generation, targetURL, fileManager in
                if failManifestWrites.value {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
                }
                try RecordingJournalManifestWriter.live.write(
                    data,
                    generation,
                    targetURL,
                    fileManager
                )
            })
        )
        let recordingID = UUID()
        let callback = TerminalFailureCapture()
        let controller = try SegmentedRecordingJournalController(
            request: SegmentedRecordingJournalCreateRequest(
                recordingID: recordingID,
                segmentID: UUID(),
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                monotonicAnchorNanoseconds: 1_000_000_000,
                sources: [RecordingJournalSegmentSourceRequest(
                    id: UUID(),
                    kind: .microphone
                )],
                pipeline: makePipelineSnapshot()
            ),
            store: store,
            callbackQueue: DispatchQueue(label: "manifest-checkpoint-callback"),
            onTerminalPersistenceFailure: callback.record,
            makeWriter: { try RecordingPCMJournalWriter(session: $0, store: $1) }
        )
        controller.activeSegment.microphoneSink?.enqueue(Data([0x01, 0x00]))
        failManifestWrites.value = true

        do {
            try controller.checkpoint()
            throw TestFailure("manifest checkpoint failure must throw")
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain {
            // expected
        }
        guard callback.wait() == .success else {
            throw TestFailure("manifest checkpoint terminal callback did not arrive")
        }
        try expectEqual(callback.failures.count, 1, "manifest callback count")
        try expectEqual(
            callback.failures.first?.failure.reason,
            .journalIOFailure,
            "manifest callback reason"
        )
        try expectEqual(
            callback.failures.first?.failure.operation,
            .writeManifest,
            "manifest callback operation"
        )

        failManifestWrites.value = false
        _ = try controller.closeAfterPersistenceFailure()
        let manifest = try store.loadManifest(recordingID: recordingID)
        try expectEqual(manifest.state, .recoverable, "manifest failure recoverable state")
        try expectEqual(
            manifest.interruptionReason,
            .journalIOFailure,
            "manifest failure durable reason"
        )
    }

    private static func switchManifestFailureConvergesToTerminalCallback() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "quill-segmented-switch-failure-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let failManifestWrites = LockedFlag()
        let store = RecordingJournalStore(
            audioDirectory: root.appendingPathComponent("audio", isDirectory: true),
            manifestWriter: RecordingJournalManifestWriter(write: { data, generation, targetURL, fileManager in
                if failManifestWrites.value {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
                }
                try RecordingJournalManifestWriter.live.write(
                    data,
                    generation,
                    targetURL,
                    fileManager
                )
            })
        )
        let recordingID = UUID()
        let callback = TerminalFailureCapture()
        let controller = try SegmentedRecordingJournalController(
            request: SegmentedRecordingJournalCreateRequest(
                recordingID: recordingID,
                segmentID: UUID(),
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                monotonicAnchorNanoseconds: 1_000_000_000,
                sources: [RecordingJournalSegmentSourceRequest(
                    id: UUID(),
                    kind: .microphone
                )],
                pipeline: makePipelineSnapshot()
            ),
            store: store,
            callbackQueue: DispatchQueue(label: "manifest-switch-callback"),
            onTerminalPersistenceFailure: callback.record,
            makeWriter: { try RecordingPCMJournalWriter(session: $0, store: $1) }
        )
        controller.activeSegment.microphoneSink?.enqueue(Data([0x01, 0x00]))
        try controller.checkpoint()
        controller.activeSegment.microphoneSink?.enqueue(Data([0x02, 0x00]))
        failManifestWrites.value = true

        do {
            _ = try controller.switchSegment(
                segmentID: UUID(),
                sources: [RecordingJournalSegmentSourceRequest(
                    id: UUID(),
                    kind: .systemAudio
                )]
            )
            throw TestFailure("switch manifest failure must throw")
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain {
            // expected
        }
        guard callback.wait() == .success else {
            throw TestFailure("switch manifest terminal callback did not arrive")
        }
        try expectEqual(
            callback.failures.first?.failure.reason,
            .journalIOFailure,
            "switch manifest reason"
        )
        failManifestWrites.value = false
        _ = try controller.closeAfterPersistenceFailure()
        let manifest = try store.loadManifest(recordingID: recordingID)
        try expectEqual(manifest.state, .recoverable, "switch failure recoverable state")
        try expectEqual(
            manifest.sources[0].committedDataByteCount,
            2,
            "switch failure preserves prior boundary"
        )
    }

    private static func timerSyncFailureDoesNotAlsoReportDiagnosticFailure() throws {
        try withFixture { fixture in
            let terminal = TerminalFailureCapture()
            let diagnostic = ErrorCapture()
            let controller = try SegmentedRecordingJournalController(
                request: fixture.request(sources: [RecordingJournalSegmentSourceRequest(
                    id: fixture.microphoneSourceID,
                    kind: .microphone
                )]),
                store: fixture.store,
                callbackQueue: DispatchQueue(label: "timer-terminal-callback"),
                onTerminalPersistenceFailure: terminal.record,
                makeWriter: { session, store in
                    try RecordingPCMJournalWriter(
                        session: session,
                        store: store,
                        operations: RecordingPCMJournalWriterOperations(
                            write: { try $0.write(contentsOf: $1) },
                            fullSync: { _ in
                                throw NSError(
                                    domain: NSPOSIXErrorDomain,
                                    code: Int(EACCES)
                                )
                            },
                            close: { try $0.close() }
                        )
                    )
                }
            )
            controller.activeSegment.microphoneSink?.enqueue(Data([0x01, 0x00]))
            controller.startCheckpointing(
                every: 0.01,
                callbackQueue: DispatchQueue(label: "timer-diagnostic-callback"),
                onFirstFailure: diagnostic.record
            )
            guard terminal.wait() == .success else {
                throw TestFailure("timer terminal callback did not arrive")
            }
            try expectEqual(
                diagnostic.wait(timeout: 0.05),
                .timedOut,
                "timer diagnostic callback absence"
            )
            _ = try controller.closeAfterPersistenceFailure()
        }
    }

    private static func stopManifestFailureCanUseFailureClose() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "quill-segmented-stop-failure-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let failManifestWrites = LockedFlag()
        let store = RecordingJournalStore(
            audioDirectory: root.appendingPathComponent("audio", isDirectory: true),
            manifestWriter: RecordingJournalManifestWriter(write: { data, generation, targetURL, fileManager in
                if failManifestWrites.value {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
                }
                try RecordingJournalManifestWriter.live.write(
                    data,
                    generation,
                    targetURL,
                    fileManager
                )
            })
        )
        let recordingID = UUID()
        let sourceID = UUID()
        let terminal = TerminalFailureCapture()
        let controller = try SegmentedRecordingJournalController(
            request: SegmentedRecordingJournalCreateRequest(
                recordingID: recordingID,
                segmentID: UUID(),
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                monotonicAnchorNanoseconds: 1_000_000_000,
                sources: [RecordingJournalSegmentSourceRequest(
                    id: sourceID,
                    kind: .microphone
                )],
                pipeline: makePipelineSnapshot()
            ),
            store: store,
            callbackQueue: DispatchQueue(label: "stop-terminal-callback"),
            onTerminalPersistenceFailure: terminal.record,
            makeWriter: { try RecordingPCMJournalWriter(session: $0, store: $1) }
        )
        controller.activeSegment.microphoneSink?.enqueue(Data([0x01, 0x00]))
        try controller.checkpoint()
        controller.activeSegment.microphoneSink?.enqueue(Data([0x02, 0x00]))
        failManifestWrites.value = true

        do {
            try controller.stopAndClose()
            throw TestFailure("stop manifest failure must throw")
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain {
            // expected
        }
        guard terminal.wait() == .success else {
            throw TestFailure("stop manifest terminal callback did not arrive")
        }
        failManifestWrites.value = false
        _ = try controller.closeAfterPersistenceFailure()
        let manifest = try store.loadManifest(recordingID: recordingID)
        try expectEqual(manifest.state, .recoverable, "stop failure recoverable state")
        try expectEqual(manifest.interruptionReason, .storageFull, "stop failure reason")
        try expectEqual(
            manifest.sources[0].committedDataByteCount,
            2,
            "stop failure last durable boundary"
        )
    }

    private static func terminalAppendFailureConvergesAndPreservesHealthySource() throws {
        try withFixture { fixture in
            let callback = TerminalFailureCapture()
            let microphoneCloseCount = LockedCounter()
            let systemCloseCount = LockedCounter()
            let controller = try SegmentedRecordingJournalController(
                request: fixture.request(sources: [
                    RecordingJournalSegmentSourceRequest(
                        id: fixture.microphoneSourceID,
                        kind: .microphone
                    ),
                    RecordingJournalSegmentSourceRequest(
                        id: fixture.systemAudioSourceID,
                        kind: .systemAudio
                    )
                ]),
                store: fixture.store,
                callbackQueue: DispatchQueue(label: "controller-terminal-callback"),
                onTerminalPersistenceFailure: callback.record,
                makeWriter: { session, store in
                    let isMicrophone = session.sourceID == fixture.microphoneSourceID
                    return try RecordingPCMJournalWriter(
                        session: session,
                        store: store,
                        operations: RecordingPCMJournalWriterOperations(
                            write: { handle, data in
                                if isMicrophone {
                                    throw NSError(
                                        domain: NSPOSIXErrorDomain,
                                        code: Int(ENOSPC)
                                    )
                                }
                                try handle.write(contentsOf: data)
                            },
                            fullSync: RecordingJournalDurability.fullSync,
                            close: { handle in
                                if isMicrophone {
                                    microphoneCloseCount.increment()
                                } else {
                                    systemCloseCount.increment()
                                }
                                try handle.close()
                            }
                        )
                    )
                }
            )
            controller.activeSegment.microphoneSink?.enqueue(Data([0x01, 0x00]))
            controller.activeSegment.systemAudioSink?.enqueue(Data([0x02, 0x00]))
            guard callback.wait() == .success else {
                throw TestFailure("terminal callback did not arrive")
            }

            do {
                try controller.checkpoint()
                throw TestFailure("terminal controller checkpoint must fail")
            } catch SegmentedRecordingJournalControllerError.controllerClosed {
                // expected
            }
            do {
                _ = try controller.switchSegment(
                    segmentID: UUID(),
                    sources: [RecordingJournalSegmentSourceRequest(
                        id: UUID(),
                        kind: .microphone
                    )]
                )
                throw TestFailure("terminal controller switch must fail")
            } catch SegmentedRecordingJournalControllerError.controllerClosed {
                // expected
            }

            let result = try controller.closeAfterPersistenceFailure()
            let repeated = try controller.closeAfterPersistenceFailure()
            let manifest = try fixture.store.loadManifest(recordingID: fixture.recordingID)

            try expectEqual(callback.failures.count, 1, "recording callback count")
            try expectEqual(
                callback.failures.first?.segmentSequence,
                0,
                "failure segment sequence"
            )
            try expectEqual(
                callback.failures.first?.sourceKind,
                .microphone,
                "failure source kind"
            )
            try expectEqual(result, repeated, "idempotent failure close")
            try expectEqual(result.interruptionReason, .storageFull, "terminal reason")
            try expectEqual(microphoneCloseCount.value, 1, "microphone close count")
            try expectEqual(systemCloseCount.value, 1, "system close count")
            try expectEqual(manifest.state, .recoverable, "terminal manifest state")
            try expectEqual(manifest.interruptionReason, .storageFull, "terminal manifest reason")
            try expectEqual(
                manifest.sources.first(where: { $0.id == fixture.microphoneSourceID })?
                    .committedDataByteCount,
                0,
                "failed source boundary"
            )
            try expectEqual(
                manifest.sources.first(where: { $0.id == fixture.systemAudioSourceID })?
                    .committedDataByteCount,
                2,
                "healthy source boundary"
            )
        }
    }

    private static func withFixture(
        _ body: (Fixture) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "quill-segmented-controller-tests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let recordingID = UUID()
        let firstSegmentID = UUID()
        let anchor: UInt64 = 1_000_000_000
        let pipeline = makePipelineSnapshot()
        let store = RecordingJournalStore(
            audioDirectory: root.appendingPathComponent("audio", isDirectory: true)
        )
        try body(Fixture(
            recordingID: recordingID,
            firstSegmentID: firstSegmentID,
            microphoneSourceID: UUID(),
            systemAudioSourceID: UUID(),
            anchor: anchor,
            pipeline: pipeline,
            store: store
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
                contextCaptureEnabled: false,
                instructionExecutionGuardEnabled: true,
                customVocabulary: [],
                customSystemPrompt: nil
            )
        )
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
        let recordingID: UUID
        let firstSegmentID: UUID
        let microphoneSourceID: UUID
        let systemAudioSourceID: UUID
        let anchor: UInt64
        let pipeline: RecordingPipelineSnapshot
        let store: RecordingJournalStore

        func request(
            sources: [RecordingJournalSegmentSourceRequest]
        ) -> SegmentedRecordingJournalCreateRequest {
            SegmentedRecordingJournalCreateRequest(
                recordingID: recordingID,
                segmentID: firstSegmentID,
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                monotonicAnchorNanoseconds: anchor,
                sources: sources,
                pipeline: pipeline
            )
        }
    }

    private final class TerminalFailureCapture: @unchecked Sendable {
        private let lock = NSLock()
        private let semaphore = DispatchSemaphore(value: 0)
        private var storage: [RecordingJournalSourcePersistenceFailure] = []

        var failures: [RecordingJournalSourcePersistenceFailure] {
            lock.withLock { storage }
        }

        func record(_ failure: RecordingJournalSourcePersistenceFailure) {
            lock.withLock { storage.append(failure) }
            semaphore.signal()
        }

        func wait() -> DispatchTimeoutResult {
            semaphore.wait(timeout: .now() + 1)
        }
    }

    private final class ErrorCapture: @unchecked Sendable {
        private let lock = NSLock()
        private let semaphore = DispatchSemaphore(value: 0)
        private var storage: [Error] = []

        func record(_ error: Error) {
            lock.withLock { storage.append(error) }
            semaphore.signal()
        }

        func wait(timeout: TimeInterval = 1) -> DispatchTimeoutResult {
            semaphore.wait(timeout: .now() + timeout)
        }
    }

    private final class LockedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = false

        var value: Bool {
            get { lock.withLock { storage } }
            set { lock.withLock { storage = newValue } }
        }
    }

    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = 0

        var value: Int { lock.withLock { storage } }

        func increment() {
            lock.withLock { storage += 1 }
        }
    }

    private struct TestFailure: Error, CustomStringConvertible {
        let description: String

        init(_ description: String) {
            self.description = description
        }
    }
}
