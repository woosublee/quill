import Foundation

@main
struct RecordingJournalManifestTests {
    static func main() {
        do {
            try canonicalFormatMatchesRecorderContract()
            try manifestRoundTripPreservesStableMetadata()
            try legacyPromotionWithoutRecoveryModeDefaultsToComplete()
            try promotionRoundTripPreservesRecoveryMode()
            try partialPromotionRoundTripPreservesRecoveryIssues()
            try interruptedManifestAndPromotionRoundTrip()
            try conflictingInterruptionMetadataIsRejected()
            try promotionInterruptionReasonMustMatchManifest()
            try combinedManifestAcceptsCanonicalShape()
            try segmentedManifestAcceptsOrderedShape()
            try segmentedManifestRejectsInvalidShapes()
            try legacySingleSourceManifestShapeRemainsValid()
            try manifestRejectsSourceModeShapeMismatch()
            try stateMachineAllowsOnlyDocumentedTransitions()
            try sameStateTransitionIsIdempotent()
            try conflictingIdempotentTransitionIsRejected()
            try manifestRejectsUnsupportedSchemaAndUnsafeFileNames()
            try manifestRejectsOverflowingCountsWithoutTrapping()
            try transitionRejectsOverflowingGenerationWithoutTrapping()
            try encodedManifestContainsNoCredentialFields()
            print("RecordingJournalManifestTests passed")
        } catch {
            fputs("RecordingJournalManifestTests failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func canonicalFormatMatchesRecorderContract() throws {
        let format = RecordingPCMFormat.canonical
        try expectEqual(format.sampleRate, 16_000, "sample rate")
        try expectEqual(format.channelCount, 1, "channel count")
        try expectEqual(format.bitsPerSample, 16, "bits per sample")
        try expectEqual(format.bytesPerFrame, 2, "bytes per frame")
        guard format.isInterleaved, format.isSigned, format.isLittleEndian else {
            throw TestFailure("canonical PCM must be interleaved signed little-endian")
        }
    }

    private static func manifestRoundTripPreservesStableMetadata() throws {
        let manifest = try makeManifest()
        let data = try RecordingJournalCoding.makeEncoder().encode(manifest)
        let decoded = try RecordingJournalCoding.makeDecoder().decode(
            RecordingJournalManifest.self,
            from: data
        )

        try expectEqual(decoded, manifest, "manifest round trip")
        try decoded.validate()
    }

    private static func legacyPromotionWithoutRecoveryModeDefaultsToComplete() throws {
        let recording = try makeManifest()
        let stopping = try recording.transitioned(
            to: .stopping,
            now: fixedDate.addingTimeInterval(1)
        )
        let promoted = try stopping.transitioned(
            to: .promoted,
            promotion: RecordingPromotion(
                fileName: recordingID.uuidString.lowercased() + ".wav",
                dataByteCount: 8,
                frameCount: 4
            ),
            now: fixedDate.addingTimeInterval(2)
        )
        let data = try RecordingJournalCoding.makeEncoder().encode(promoted)
        let json = String(decoding: data, as: UTF8.self)
        guard !json.contains("recoveryMode") else {
            throw TestFailure("legacy nil recovery mode must be omitted from schema-v1 JSON")
        }
        guard !json.contains("interruptionReason") else {
            throw TestFailure("legacy nil interruption reason must be omitted from schema-v1 JSON")
        }
        let decoded = try RecordingJournalCoding.makeDecoder().decode(
            RecordingJournalManifest.self,
            from: data
        )

        try expectEqual(decoded.interruptionReason, nil, "legacy manifest interruption reason")
        try expectEqual(decoded.promotion?.interruptionReason, nil, "legacy promotion interruption reason")
        try expectEqual(decoded.promotion?.recoveryMode, nil, "legacy recovery mode")
        try expectEqual(
            decoded.promotion?.resolvedRecoveryMode,
            .complete,
            "legacy resolved recovery mode"
        )
        try expectEqual(decoded.promotion?.recoveryIssues, nil, "legacy recovery issues")
        try expectEqual(
            decoded.promotion?.resolvedRecoveryIssues,
            [],
            "legacy resolved recovery issues"
        )
    }

    private static func promotionRoundTripPreservesRecoveryMode() throws {
        let recording = try makeManifest()
        let stopping = try recording.transitioned(
            to: .stopping,
            now: fixedDate.addingTimeInterval(1)
        )
        let promoted = try stopping.transitioned(
            to: .promoted,
            promotion: RecordingPromotion(
                fileName: recordingID.uuidString.lowercased() + ".wav",
                dataByteCount: 8,
                frameCount: 4,
                recoveryMode: .microphoneOnly
            ),
            now: fixedDate.addingTimeInterval(2)
        )
        let data = try RecordingJournalCoding.makeEncoder().encode(promoted)
        let decoded = try RecordingJournalCoding.makeDecoder().decode(
            RecordingJournalManifest.self,
            from: data
        )

        try expectEqual(
            decoded.promotion?.recoveryMode,
            .microphoneOnly,
            "round-trip recovery mode"
        )
        try expectEqual(
            decoded.promotion?.resolvedRecoveryMode,
            .microphoneOnly,
            "round-trip resolved recovery mode"
        )
    }

    private static func partialPromotionRoundTripPreservesRecoveryIssues() throws {
        let issues = [
            RecordingRecoveryIssue(
                segmentSequence: 1,
                sourceKind: .systemAudio,
                reason: .sourceMissing
            ),
            RecordingRecoveryIssue(
                segmentSequence: 2,
                sourceKind: nil,
                reason: .committedPayloadUnavailable
            )
        ]
        var recording = try makeSegmentedManifest()
        recording.state = .stopping
        let promoted = try recording.transitioned(
            to: .promoted,
            promotion: RecordingPromotion(
                fileName: recordingID.uuidString.lowercased() + ".wav",
                dataByteCount: 8,
                frameCount: 4,
                recoveryMode: .partial,
                recoveryIssues: issues
            ),
            now: fixedDate.addingTimeInterval(2)
        )
        let data = try RecordingJournalCoding.makeEncoder().encode(promoted)
        let decoded = try RecordingJournalCoding.makeDecoder().decode(
            RecordingJournalManifest.self,
            from: data
        )

        try expectEqual(decoded.promotion?.recoveryMode, .partial, "partial mode")
        try expectEqual(decoded.promotion?.recoveryIssues, issues, "partial issues")
        try expectEqual(
            decoded.promotion?.resolvedRecoveryIssues,
            issues,
            "resolved partial issues"
        )

        let legacyData = try RecordingJournalCoding.makeEncoder().encode(
            try makeManifest()
        )
        let legacy = try RecordingJournalCoding.makeDecoder().decode(
            RecordingJournalManifest.self,
            from: legacyData
        )
        try expectEqual(
            legacy.promotion?.resolvedRecoveryIssues ?? [],
            [],
            "legacy resolved recovery issues"
        )
    }

    private static func interruptedManifestAndPromotionRoundTrip() throws {
        var recording = try makeSegmentedManifest()
        recording.state = .recording
        let recoverable = try recording.transitioned(
            to: .recoverable,
            interruptionReason: .storageFull,
            now: fixedDate.addingTimeInterval(1)
        )
        let issues = [RecordingRecoveryIssue(
            segmentSequence: 1,
            sourceKind: .systemAudio,
            reason: .sourceMissing
        )]
        let promoted = try recoverable.transitioned(
            to: .promoted,
            promotion: RecordingPromotion(
                fileName: recordingID.uuidString.lowercased() + ".wav",
                dataByteCount: 8,
                frameCount: 4,
                recoveryMode: .partial,
                recoveryIssues: issues,
                interruptionReason: .storageFull
            ),
            now: fixedDate.addingTimeInterval(2)
        )
        let data = try RecordingJournalCoding.makeEncoder().encode(promoted)
        let decoded = try RecordingJournalCoding.makeDecoder().decode(
            RecordingJournalManifest.self,
            from: data
        )

        try expectEqual(decoded.interruptionReason, .storageFull, "manifest interruption reason")
        try expectEqual(
            decoded.promotion?.interruptionReason,
            .storageFull,
            "promotion interruption reason"
        )
        try expectEqual(decoded.promotion?.recoveryMode, .partial, "interrupted partial mode")
        try decoded.validate()
    }

    private static func conflictingInterruptionMetadataIsRejected() throws {
        let recoverable = try makeManifest().transitioned(
            to: .recoverable,
            interruptionReason: .storageFull,
            now: fixedDate.addingTimeInterval(1)
        )

        do {
            _ = try recoverable.transitioned(
                to: .recoverable,
                interruptionReason: .permissionDenied,
                now: fixedDate.addingTimeInterval(2)
            )
            throw TestFailure("conflicting interruption reason must fail")
        } catch RecordingJournalError.conflictingTransitionMetadata {
            // expected
        }
    }

    private static func promotionInterruptionReasonMustMatchManifest() throws {
        let recoverable = try makeManifest().transitioned(
            to: .recoverable,
            interruptionReason: .storageFull,
            now: fixedDate.addingTimeInterval(1)
        )

        do {
            _ = try recoverable.transitioned(
                to: .promoted,
                promotion: RecordingPromotion(
                    fileName: recordingID.uuidString.lowercased() + ".wav",
                    dataByteCount: 8,
                    frameCount: 4,
                    interruptionReason: .permissionDenied
                ),
                now: fixedDate.addingTimeInterval(2)
            )
            throw TestFailure("promotion reason mismatch must fail")
        } catch RecordingJournalError.conflictingTransitionMetadata {
            // expected
        }
    }

    private static func combinedManifestAcceptsCanonicalShape() throws {
        let manifest = try makeCombinedManifest()

        try manifest.validate()
        try expectEqual(manifest.sourceMode, .combined, "combined source mode")
        try expectEqual(manifest.sources.count, 2, "combined source count")
        try expectEqual(
            Set(manifest.sources.map(\.kind)),
            Set([.microphone, .systemAudio]),
            "combined source kinds"
        )
        try expectEqual(
            Set(manifest.segments[0].sourceIDs),
            Set(manifest.sources.map(\.id)),
            "combined segment sources"
        )
    }

    private static func segmentedManifestAcceptsOrderedShape() throws {
        let manifest = try makeSegmentedManifest()

        try manifest.validate()
        try expectEqual(manifest.sourceMode, .segmented, "segmented source mode")
        try expectEqual(manifest.segments.map(\.sequence), [0, 1, 2], "segment order")
        try expectEqual(
            manifest.segments.map { segment in
                Set(manifest.sources.filter { $0.segmentID == segment.id }.map(\.kind))
            },
            [Set([.microphone]), Set([.microphone, .systemAudio]), Set([.systemAudio])],
            "segment source kinds"
        )
    }

    private static func segmentedManifestRejectsInvalidShapes() throws {
        var duplicateSequence = try makeSegmentedManifest()
        duplicateSequence.segments[2] = RecordingJournalSegment(
            id: duplicateSequence.segments[2].id,
            sequence: 1,
            sourceIDs: duplicateSequence.segments[2].sourceIDs
        )
        try expectInvalidManifest(duplicateSequence, "duplicate segment sequence")

        var nonContiguousSequence = try makeSegmentedManifest()
        nonContiguousSequence.segments[2] = RecordingJournalSegment(
            id: nonContiguousSequence.segments[2].id,
            sequence: 3,
            sourceIDs: nonContiguousSequence.segments[2].sourceIDs
        )
        try expectInvalidManifest(nonContiguousSequence, "non-contiguous segment sequence")

        var duplicateFilename = try makeSegmentedManifest()
        duplicateFilename.sources[1].fileName = duplicateFilename.sources[0].fileName
        try expectInvalidManifest(duplicateFilename, "duplicate segmented source filename")

        var duplicateKind = try makeSegmentedManifest()
        duplicateKind.sources[2] = replacingSource(
            duplicateKind.sources[2],
            kind: .microphone
        )
        try expectInvalidManifest(duplicateKind, "duplicate source kind in segment")

        var mismatchedSegment = try makeSegmentedManifest()
        mismatchedSegment.sources[1] = replacingSource(
            mismatchedSegment.sources[1],
            segmentID: mismatchedSegment.segments[0].id
        )
        try expectInvalidManifest(mismatchedSegment, "source segment mismatch")

        var unknownSource = try makeSegmentedManifest()
        unknownSource.segments[1] = RecordingJournalSegment(
            id: unknownSource.segments[1].id,
            sequence: unknownSource.segments[1].sequence,
            sourceIDs: unknownSource.segments[1].sourceIDs + [UUID()]
        )
        try expectInvalidManifest(unknownSource, "unknown segmented source")

        var unlistedSource = try makeSegmentedManifest()
        unlistedSource.segments[1] = RecordingJournalSegment(
            id: unlistedSource.segments[1].id,
            sequence: unlistedSource.segments[1].sequence,
            sourceIDs: [unlistedSource.segments[1].sourceIDs[0]]
        )
        try expectInvalidManifest(unlistedSource, "source listed by no segment")

        var emptySources = try makeSegmentedManifest()
        emptySources.sources = []
        try expectInvalidManifest(emptySources, "empty segmented source list")

        var absentIssueSequence = try makeSegmentedManifest()
        absentIssueSequence.state = .promoted
        absentIssueSequence.promotion = RecordingPromotion(
            fileName: recordingID.uuidString.lowercased() + ".wav",
            dataByteCount: 2,
            frameCount: 1,
            recoveryMode: .partial,
            recoveryIssues: [RecordingRecoveryIssue(
                segmentSequence: 3,
                sourceKind: .microphone,
                reason: .sourceMissing
            )]
        )
        try expectInvalidManifest(absentIssueSequence, "absent recovery issue sequence")

        var negativeIssueSequence = try makeSegmentedManifest()
        negativeIssueSequence.state = .promoted
        negativeIssueSequence.promotion = RecordingPromotion(
            fileName: recordingID.uuidString.lowercased() + ".wav",
            dataByteCount: 2,
            frameCount: 1,
            recoveryMode: .partial,
            recoveryIssues: [RecordingRecoveryIssue(
                segmentSequence: -1,
                sourceKind: nil,
                reason: .committedPayloadUnavailable
            )]
        )
        try expectInvalidManifest(negativeIssueSequence, "negative recovery issue sequence")
    }

    private static func legacySingleSourceManifestShapeRemainsValid() throws {
        var manifest = try makeManifest()
        let secondSegmentID = UUID()
        manifest.sources.append(RecordingJournalSource(
            id: systemSourceID,
            kind: .systemAudio,
            fileName: "microphone.wav.part",
            storageLayout: .reservedWAVHeader44,
            committedDataByteCount: 0,
            committedFrameCount: 0,
            firstCommittedFrameOffset: nil,
            segmentID: secondSegmentID
        ))
        manifest = RecordingJournalManifest(
            schemaVersion: manifest.schemaVersion,
            generation: manifest.generation,
            recordingID: manifest.recordingID,
            startedAt: manifest.startedAt,
            updatedAt: manifest.updatedAt,
            monotonicAnchorNanoseconds: manifest.monotonicAnchorNanoseconds,
            state: manifest.state,
            sourceMode: .microphone,
            pcmFormat: manifest.pcmFormat,
            sources: manifest.sources,
            segments: [
                manifest.segments[0],
                RecordingJournalSegment(
                    id: secondSegmentID,
                    sequence: 1,
                    sourceIDs: [systemSourceID]
                )
            ],
            pipeline: manifest.pipeline,
            promotion: nil,
            historyItemID: nil
        )

        try manifest.validate()
    }

    private static func manifestRejectsSourceModeShapeMismatch() throws {
        try expectInvalidManifest(
            makeCombinedManifest(systemSourceKind: .microphone),
            "combined duplicate source kind"
        )
        try expectInvalidManifest(
            makeCombinedManifest(includeSystemSource: false),
            "combined mode missing System Audio source"
        )
        try expectInvalidManifest(
            makeCombinedManifest(segmentSourceIDs: [sourceID]),
            "combined segment missing a source"
        )
        try expectInvalidManifest(
            makeCombinedManifest(
                systemSourceFileName: "microphone.wav.part"
            ),
            "combined duplicate source filename"
        )
    }

    private static func stateMachineAllowsOnlyDocumentedTransitions() throws {
        let recording = try makeManifest()
        let stopping = try recording.transitioned(
            to: .stopping,
            now: fixedDate.addingTimeInterval(1)
        )
        try expectEqual(stopping.state, .stopping, "stopping state")
        try expectEqual(stopping.generation, 2, "stopping generation")

        let promotion = RecordingPromotion(
            fileName: recording.recordingID.uuidString.lowercased() + ".wav",
            dataByteCount: 8,
            frameCount: 4
        )
        let promoted = try stopping.transitioned(
            to: .promoted,
            promotion: promotion,
            now: fixedDate.addingTimeInterval(2)
        )
        try expectEqual(promoted.promotion, promotion, "promotion metadata")

        let historyStored = try promoted.transitioned(
            to: .historyStored,
            historyItemID: recording.recordingID,
            now: fixedDate.addingTimeInterval(3)
        )
        let finalized = try historyStored.transitioned(
            to: .finalized,
            now: fixedDate.addingTimeInterval(4)
        )
        try expectEqual(finalized.state, .finalized, "finalized state")

        let recoverable = try recording.transitioned(
            to: .recoverable,
            now: fixedDate.addingTimeInterval(1)
        )
        try expectEqual(recoverable.state, .recoverable, "recoverable state")

        do {
            _ = try recording.transitioned(
                to: .promoted,
                promotion: promotion,
                now: fixedDate.addingTimeInterval(1)
            )
            throw TestFailure("recording must not skip directly to promoted")
        } catch RecordingJournalError.invalidStateTransition {
            // expected
        }

        do {
            _ = try promoted.transitioned(
                to: .recording,
                now: fixedDate.addingTimeInterval(4)
            )
            throw TestFailure("backward transition must be rejected")
        } catch RecordingJournalError.invalidStateTransition {
            // expected
        }
    }

    private static func sameStateTransitionIsIdempotent() throws {
        let recording = try makeManifest()
        let unchanged = try recording.transitioned(
            to: .recording,
            now: fixedDate.addingTimeInterval(20)
        )
        try expectEqual(unchanged, recording, "recording no-op transition")

        let stopping = try recording.transitioned(
            to: .stopping,
            now: fixedDate.addingTimeInterval(1)
        )
        let promotion = RecordingPromotion(
            fileName: recording.recordingID.uuidString.lowercased() + ".wav",
            dataByteCount: 8,
            frameCount: 4
        )
        let promoted = try stopping.transitioned(
            to: .promoted,
            promotion: promotion,
            now: fixedDate.addingTimeInterval(2)
        )
        let repeated = try promoted.transitioned(
            to: .promoted,
            promotion: promotion,
            now: fixedDate.addingTimeInterval(30)
        )
        try expectEqual(repeated, promoted, "promoted no-op transition")
    }

    private static func conflictingIdempotentTransitionIsRejected() throws {
        let recording = try makeManifest()
        let stopping = try recording.transitioned(
            to: .stopping,
            now: fixedDate.addingTimeInterval(1)
        )
        let promotion = RecordingPromotion(
            fileName: recording.recordingID.uuidString.lowercased() + ".wav",
            dataByteCount: 8,
            frameCount: 4
        )
        let promoted = try stopping.transitioned(
            to: .promoted,
            promotion: promotion,
            now: fixedDate.addingTimeInterval(2)
        )

        do {
            _ = try promoted.transitioned(
                to: .promoted,
                promotion: RecordingPromotion(
                    fileName: promotion.fileName,
                    dataByteCount: 10,
                    frameCount: 5
                ),
                now: fixedDate.addingTimeInterval(3)
            )
            throw TestFailure("conflicting promoted transition must fail")
        } catch RecordingJournalError.conflictingTransitionMetadata {
            // expected
        }
    }

    private static func manifestRejectsUnsupportedSchemaAndUnsafeFileNames() throws {
        var unsupported = try makeManifest()
        unsupported.schemaVersion = 2
        do {
            try unsupported.validate()
            throw TestFailure("unsupported schema must fail validation")
        } catch RecordingJournalError.unsupportedSchemaVersion(2) {
            // expected
        }

        for unsafeName in ["", "manifest.json", "../microphone.wav.part", "nested/microphone.wav.part", "/tmp/audio"] {
            var manifest = try makeManifest()
            manifest.sources[0].fileName = unsafeName
            do {
                try manifest.validate()
                throw TestFailure("unsafe filename should fail: \(unsafeName)")
            } catch RecordingJournalError.unsafeRelativeFileName {
                // expected
            }
        }
    }

    private static func manifestRejectsOverflowingCountsWithoutTrapping() throws {
        var sourceOverflow = try makeManifest()
        sourceOverflow.sources[0].committedDataByteCount = 2
        sourceOverflow.sources[0].committedFrameCount = UInt64.max
        do {
            try sourceOverflow.validate()
            throw TestFailure("overflowing source counts must fail validation")
        } catch RecordingJournalError.invalidManifest {
            // expected
        }

        var promotionOverflow = try makeManifest()
        promotionOverflow.state = .promoted
        promotionOverflow.promotion = RecordingPromotion(
            fileName: recordingID.uuidString.lowercased() + ".wav",
            dataByteCount: 2,
            frameCount: UInt64.max
        )
        do {
            try promotionOverflow.validate()
            throw TestFailure("overflowing promotion counts must fail validation")
        } catch RecordingJournalError.invalidManifest {
            // expected
        }
    }

    private static func transitionRejectsOverflowingGenerationWithoutTrapping() throws {
        var manifest = try makeManifest()
        manifest.generation = UInt64.max

        do {
            _ = try manifest.transitioned(
                to: .stopping,
                now: fixedDate.addingTimeInterval(1)
            )
            throw TestFailure("overflowing generation must fail transition")
        } catch RecordingJournalError.invalidManifest {
            // expected
        }
    }

    private static func encodedManifestContainsNoCredentialFields() throws {
        let data = try RecordingJournalCoding.makeEncoder().encode(try makeManifest())
        let json = String(decoding: data, as: UTF8.self).lowercased()
        for forbidden in ["apikey", "api_key", "oauth", "credential", "secret", "baseurl", "providerurl"] {
            guard !json.contains(forbidden) else {
                throw TestFailure("manifest JSON must not contain credential field: \(forbidden)")
            }
        }
    }

    private static func makeManifest() throws -> RecordingJournalManifest {
        let source = RecordingJournalSource(
            id: sourceID,
            kind: .microphone,
            fileName: "microphone.wav.part",
            storageLayout: .reservedWAVHeader44,
            committedDataByteCount: 0,
            committedFrameCount: 0,
            firstCommittedFrameOffset: nil,
            segmentID: segmentID
        )
        let segment = RecordingJournalSegment(
            id: segmentID,
            sequence: 0,
            sourceIDs: [sourceID]
        )
        let manifest = RecordingJournalManifest(
            schemaVersion: 1,
            generation: 1,
            recordingID: recordingID,
            startedAt: fixedDate,
            updatedAt: fixedDate,
            monotonicAnchorNanoseconds: 123_456,
            state: .recording,
            sourceMode: .microphone,
            pcmFormat: .canonical,
            sources: [source],
            segments: [segment],
            pipeline: RecordingPipelineSnapshot(
                trigger: .toggle,
                intent: .dictation,
                selectedText: nil,
                title: "Recovered note",
                calendar: nil,
                transcription: RecordingTranscriptionSnapshot(
                    backend: .apiStandard,
                    modelID: "whisper-large-v3",
                    spokenLanguageCode: "ko",
                    providerSelection: .defaultConfiguration
                ),
                processing: RecordingProcessingSnapshot(
                    postProcessingEnabled: true,
                    preferredModelID: "qwen3.5-plus",
                    fallbackModelID: "qwen3.5-flash",
                    outputLanguage: "auto",
                    preserveExactWording: false,
                    contextCaptureEnabled: true,
                    instructionExecutionGuardEnabled: true,
                    customVocabulary: ["Quill"],
                    customSystemPrompt: nil
                )
            ),
            promotion: nil,
            historyItemID: nil
        )
        try manifest.validate()
        return manifest
    }

    private static func makeCombinedManifest(
        sourceMode: RecordingAudioSourceMode = .combined,
        systemSourceKind: RecordingJournalSourceKind = .systemAudio,
        systemSourceFileName: String = "system-audio.wav.part",
        includeSystemSource: Bool = true,
        segmentSourceIDs: [UUID]? = nil
    ) throws -> RecordingJournalManifest {
        var sources = [RecordingJournalSource(
            id: sourceID,
            kind: .microphone,
            fileName: "microphone.wav.part",
            storageLayout: .reservedWAVHeader44,
            committedDataByteCount: 0,
            committedFrameCount: 0,
            firstCommittedFrameOffset: nil,
            segmentID: segmentID
        )]
        if includeSystemSource {
            sources.append(RecordingJournalSource(
                id: systemSourceID,
                kind: systemSourceKind,
                fileName: systemSourceFileName,
                storageLayout: .reservedWAVHeader44,
                committedDataByteCount: 0,
                committedFrameCount: 0,
                firstCommittedFrameOffset: nil,
                segmentID: segmentID
            ))
        }
        return RecordingJournalManifest(
            schemaVersion: 1,
            generation: 1,
            recordingID: recordingID,
            startedAt: fixedDate,
            updatedAt: fixedDate,
            monotonicAnchorNanoseconds: 123_456,
            state: .recording,
            sourceMode: sourceMode,
            pcmFormat: .canonical,
            sources: sources,
            segments: [RecordingJournalSegment(
                id: segmentID,
                sequence: 0,
                sourceIDs: segmentSourceIDs ?? sources.map(\.id)
            )],
            pipeline: try makeManifest().pipeline,
            promotion: nil,
            historyItemID: nil
        )
    }

    private static func makeSegmentedManifest() throws -> RecordingJournalManifest {
        let firstSegmentID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let secondSegmentID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
        let thirdSegmentID = UUID(uuidString: "10000000-0000-0000-0000-000000000003")!
        let firstMicrophoneID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
        let secondMicrophoneID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        let secondSystemAudioID = UUID(uuidString: "30000000-0000-0000-0000-000000000002")!
        let thirdSystemAudioID = UUID(uuidString: "30000000-0000-0000-0000-000000000003")!
        let sources = [
            RecordingJournalSource(
                id: firstMicrophoneID,
                kind: .microphone,
                fileName: "segment-0000-microphone.wav.part",
                storageLayout: .reservedWAVHeader44,
                committedDataByteCount: 0,
                committedFrameCount: 0,
                firstCommittedFrameOffset: nil,
                segmentID: firstSegmentID
            ),
            RecordingJournalSource(
                id: secondMicrophoneID,
                kind: .microphone,
                fileName: "segment-0001-microphone.wav.part",
                storageLayout: .reservedWAVHeader44,
                committedDataByteCount: 0,
                committedFrameCount: 0,
                firstCommittedFrameOffset: nil,
                segmentID: secondSegmentID
            ),
            RecordingJournalSource(
                id: secondSystemAudioID,
                kind: .systemAudio,
                fileName: "segment-0001-system-audio.wav.part",
                storageLayout: .reservedWAVHeader44,
                committedDataByteCount: 0,
                committedFrameCount: 0,
                firstCommittedFrameOffset: nil,
                segmentID: secondSegmentID
            ),
            RecordingJournalSource(
                id: thirdSystemAudioID,
                kind: .systemAudio,
                fileName: "segment-0002-system-audio.wav.part",
                storageLayout: .reservedWAVHeader44,
                committedDataByteCount: 0,
                committedFrameCount: 0,
                firstCommittedFrameOffset: nil,
                segmentID: thirdSegmentID
            )
        ]
        return RecordingJournalManifest(
            schemaVersion: 1,
            generation: 1,
            recordingID: recordingID,
            startedAt: fixedDate,
            updatedAt: fixedDate,
            monotonicAnchorNanoseconds: 123_456,
            state: .recording,
            sourceMode: .segmented,
            pcmFormat: .canonical,
            sources: sources,
            segments: [
                RecordingJournalSegment(
                    id: firstSegmentID,
                    sequence: 0,
                    sourceIDs: [firstMicrophoneID]
                ),
                RecordingJournalSegment(
                    id: secondSegmentID,
                    sequence: 1,
                    sourceIDs: [secondMicrophoneID, secondSystemAudioID]
                ),
                RecordingJournalSegment(
                    id: thirdSegmentID,
                    sequence: 2,
                    sourceIDs: [thirdSystemAudioID]
                )
            ],
            pipeline: try makeManifest().pipeline,
            promotion: nil,
            historyItemID: nil
        )
    }

    private static func replacingSource(
        _ source: RecordingJournalSource,
        kind: RecordingJournalSourceKind? = nil,
        segmentID: UUID? = nil
    ) -> RecordingJournalSource {
        RecordingJournalSource(
            id: source.id,
            kind: kind ?? source.kind,
            fileName: source.fileName,
            storageLayout: source.storageLayout,
            committedDataByteCount: source.committedDataByteCount,
            committedFrameCount: source.committedFrameCount,
            firstCommittedFrameOffset: source.firstCommittedFrameOffset,
            segmentID: segmentID ?? source.segmentID
        )
    }

    private static func expectInvalidManifest(
        _ manifest: RecordingJournalManifest,
        _ label: String
    ) throws {
        do {
            try manifest.validate()
            throw TestFailure("\(label) must fail validation")
        } catch RecordingJournalError.invalidManifest {
            // expected
        }
    }

    private static let recordingID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    private static let sourceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private static let systemSourceID = UUID(uuidString: "66666666-7777-8888-9999-AAAAAAAAAAAA")!
    private static let segmentID = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
    private static let fixedDate = Date(timeIntervalSince1970: 1_700_000_000.123)

    private static func expectEqual<T: Equatable>(
        _ actual: T,
        _ expected: T,
        _ label: String
    ) throws {
        guard actual == expected else {
            throw TestFailure("\(label): expected \(expected), got \(actual)")
        }
    }

    private struct TestFailure: Error, CustomStringConvertible {
        let description: String

        init(_ description: String) {
            self.description = description
        }
    }
}
