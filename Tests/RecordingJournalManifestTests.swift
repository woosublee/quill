import Foundation

@main
struct RecordingJournalManifestTests {
    static func main() {
        do {
            try canonicalFormatMatchesRecorderContract()
            try manifestRoundTripPreservesStableMetadata()
            try combinedManifestAcceptsCanonicalShape()
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
