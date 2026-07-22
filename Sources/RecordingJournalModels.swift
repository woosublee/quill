import Foundation

enum RecordingJournalError: Error, Equatable {
    case unsupportedSchemaVersion(Int)
    case unsafeRelativeFileName(String)
    case invalidManifest(String)
    case invalidStateTransition(from: RecordingJournalState, to: RecordingJournalState)
    case conflictingTransitionMetadata
    case missingTransitionMetadata(RecordingJournalState)
}

struct RecordingPCMFormat: Codable, Equatable {
    let sampleRate: UInt32
    let channelCount: UInt16
    let bitsPerSample: UInt16
    let bytesPerFrame: UInt16
    let isInterleaved: Bool
    let isSigned: Bool
    let isLittleEndian: Bool

    static let canonical = RecordingPCMFormat(
        sampleRate: 16_000,
        channelCount: 1,
        bitsPerSample: 16,
        bytesPerFrame: 2,
        isInterleaved: true,
        isSigned: true,
        isLittleEndian: true
    )
}

enum RecordingJournalState: String, Codable, Equatable {
    case recording
    case stopping
    case recoverable
    case promoted
    case historyStored
    case finalized
}

enum RecordingAudioSourceMode: String, Codable, Equatable {
    case microphone
    case systemAudio
    case combined
    case segmented
}

enum RecordingJournalSourceKind: String, Codable, Equatable {
    case microphone
    case systemAudio
}

enum RecordingJournalStorageLayout: String, Codable, Equatable {
    case reservedWAVHeader44
}

enum RecordingRecoveryIssueReason: String, Codable, Equatable {
    case noCommittedAudio
    case sourceMissing
    case sourceTooShort
    case committedPayloadUnavailable
}

struct RecordingRecoveryIssue: Codable, Equatable {
    let segmentSequence: Int
    let sourceKind: RecordingJournalSourceKind?
    let reason: RecordingRecoveryIssueReason
}

struct RecordingJournalSource: Codable, Equatable {
    let id: UUID
    let kind: RecordingJournalSourceKind
    var fileName: String
    let storageLayout: RecordingJournalStorageLayout
    var committedDataByteCount: UInt64
    var committedFrameCount: UInt64
    var firstCommittedFrameOffset: UInt64?
    let segmentID: UUID
}

struct RecordingJournalSegment: Codable, Equatable {
    let id: UUID
    let sequence: Int
    let sourceIDs: [UUID]
}

enum RecordingTriggerSnapshot: String, Codable, Equatable {
    case hold
    case toggle
    case unknown
}

enum RecordingIntentSnapshot: String, Codable, Equatable {
    case dictation
    case commandAutomatic
    case commandManual
}

enum RecordingTranscriptionBackendSnapshot: String, Codable, Equatable {
    case apiStandard
    case apiRealtime
    case nativeWhisper
    case legacyMlxWhisper
    case appleLive
    case unknown
}

enum RecordingProviderSelectionSnapshot: String, Codable, Equatable {
    case defaultConfiguration
    case transcriptionOverride
}

struct RecordingTranscriptionSnapshot: Codable, Equatable {
    let backend: RecordingTranscriptionBackendSnapshot
    let modelID: String?
    let spokenLanguageCode: String
    let providerSelection: RecordingProviderSelectionSnapshot
}

struct RecordingProcessingSnapshot: Codable, Equatable {
    let postProcessingEnabled: Bool
    let preferredModelID: String?
    let fallbackModelID: String?
    let outputLanguage: String
    let contextCaptureEnabled: Bool
    let instructionExecutionGuardEnabled: Bool
    let customVocabulary: [String]
    let customSystemPrompt: String?
}

struct RecordingCalendarSnapshot: Codable, Equatable {
    let eventID: String?
    let calendarID: String?
    let title: String?
    let startDate: Date?
    let endDate: Date?
    let matchSource: String?
    let attendeeNames: [String]
}

struct RecordingPipelineSnapshot: Codable, Equatable {
    let trigger: RecordingTriggerSnapshot
    let intent: RecordingIntentSnapshot
    let selectedText: String?
    let title: String?
    let calendar: RecordingCalendarSnapshot?
    let transcription: RecordingTranscriptionSnapshot
    let processing: RecordingProcessingSnapshot
}

struct RecordingPromotion: Codable, Equatable {
    let fileName: String
    let dataByteCount: UInt64
    let frameCount: UInt64
    let recoveryMode: RecoveredRecordingMode?
    let recoveryIssues: [RecordingRecoveryIssue]?
    let interruptionReason: RecordingInterruptionReason?

    init(
        fileName: String,
        dataByteCount: UInt64,
        frameCount: UInt64,
        recoveryMode: RecoveredRecordingMode? = nil,
        recoveryIssues: [RecordingRecoveryIssue]? = nil,
        interruptionReason: RecordingInterruptionReason? = nil
    ) {
        self.fileName = fileName
        self.dataByteCount = dataByteCount
        self.frameCount = frameCount
        self.recoveryMode = recoveryMode
        self.recoveryIssues = recoveryIssues
        self.interruptionReason = interruptionReason
    }
}

struct RecordingJournalManifest: Codable, Equatable {
    var schemaVersion: Int
    var generation: UInt64
    let recordingID: UUID
    let startedAt: Date
    var updatedAt: Date
    let monotonicAnchorNanoseconds: UInt64
    var state: RecordingJournalState
    let sourceMode: RecordingAudioSourceMode
    let pcmFormat: RecordingPCMFormat
    var sources: [RecordingJournalSource]
    var segments: [RecordingJournalSegment]
    let pipeline: RecordingPipelineSnapshot
    var promotion: RecordingPromotion?
    var historyItemID: UUID?
    var interruptionReason: RecordingInterruptionReason? = nil

    func validate() throws {
        guard schemaVersion == 1 else {
            throw RecordingJournalError.unsupportedSchemaVersion(schemaVersion)
        }
        guard generation > 0 else {
            throw RecordingJournalError.invalidManifest("Manifest generation must be positive.")
        }
        guard pcmFormat == .canonical else {
            throw RecordingJournalError.invalidManifest("Unsupported PCM format.")
        }
        guard !sources.isEmpty, !segments.isEmpty else {
            throw RecordingJournalError.invalidManifest(
                "Manifest must contain a source and segment."
            )
        }

        if sourceMode == .combined {
            guard sources.count == 2,
                  segments.count == 1,
                  sources.filter({ $0.kind == .microphone }).count == 1,
                  sources.filter({ $0.kind == .systemAudio }).count == 1 else {
                throw RecordingJournalError.invalidManifest(
                    "Combined recordings require one microphone and one System Audio source."
                )
            }
        }

        let sourceIDs = Set(sources.map(\.id))
        guard sourceIDs.count == sources.count else {
            throw RecordingJournalError.invalidManifest(
                "Source identifiers must be unique."
            )
        }
        if sourceMode == .combined || sourceMode == .segmented {
            guard Set(sources.map(\.fileName)).count == sources.count else {
                throw RecordingJournalError.invalidManifest(
                    "Multi-source filenames must be unique."
                )
            }
        }
        let segmentIDs = Set(segments.map(\.id))
        guard segmentIDs.count == segments.count else {
            throw RecordingJournalError.invalidManifest("Segment identifiers must be unique.")
        }
        guard Set(segments.map(\.sequence)).count == segments.count,
              segments.map(\.sequence).allSatisfy({ $0 >= 0 }) else {
            throw RecordingJournalError.invalidManifest("Segment sequence values must be unique and nonnegative.")
        }
        if sourceMode == .segmented {
            let orderedSequences = segments.sorted { $0.sequence < $1.sequence }.map(\.sequence)
            guard orderedSequences == Array(0..<segments.count) else {
                throw RecordingJournalError.invalidManifest(
                    "Segmented recording sequences must be contiguous from zero."
                )
            }
        }

        for source in sources {
            try Self.validateRelativeFileName(source.fileName)
            guard segmentIDs.contains(source.segmentID) else {
                throw RecordingJournalError.invalidManifest("Source references an unknown segment.")
            }
            let (expectedBytes, overflow) = source.committedFrameCount.multipliedReportingOverflow(
                by: UInt64(pcmFormat.bytesPerFrame)
            )
            guard !overflow, source.committedDataByteCount == expectedBytes else {
                throw RecordingJournalError.invalidManifest("Committed byte and frame counts disagree.")
            }
        }
        if sourceMode == .combined {
            let segment = segments[0]
            let segmentSourceIDs = Set(segment.sourceIDs)
            guard segmentSourceIDs.count == segment.sourceIDs.count,
                  segmentSourceIDs == sourceIDs,
                  sources.allSatisfy({ $0.segmentID == segment.id }) else {
                throw RecordingJournalError.invalidManifest(
                    "The combined recording segment must reference every source exactly once."
                )
            }
        } else if sourceMode == .segmented {
            let sourcesByID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
            var referencedSourceIDs = Set<UUID>()
            for segment in segments {
                let segmentSourceIDs = Set(segment.sourceIDs)
                guard (1...2).contains(segment.sourceIDs.count),
                      segmentSourceIDs.count == segment.sourceIDs.count,
                      segment.sourceIDs.allSatisfy(sourceIDs.contains) else {
                    throw RecordingJournalError.invalidManifest(
                        "Segmented segments require one or two unique known sources."
                    )
                }
                let segmentSources = segment.sourceIDs.compactMap { sourcesByID[$0] }
                guard Set(segmentSources.map(\.kind)).count == segmentSources.count,
                      segmentSources.allSatisfy({ $0.segmentID == segment.id }) else {
                    throw RecordingJournalError.invalidManifest(
                        "Segmented source kinds and segment ownership must be unique."
                    )
                }
                referencedSourceIDs.formUnion(segmentSourceIDs)
            }
            guard referencedSourceIDs == sourceIDs else {
                throw RecordingJournalError.invalidManifest(
                    "Every segmented source must belong to exactly one segment."
                )
            }
        } else {
            for segment in segments {
                guard !segment.sourceIDs.isEmpty,
                      segment.sourceIDs.allSatisfy(sourceIDs.contains) else {
                    throw RecordingJournalError.invalidManifest(
                        "Segment references an unknown source."
                    )
                }
            }
        }

        if let promotion {
            guard promotion.interruptionReason == interruptionReason else {
                throw RecordingJournalError.conflictingTransitionMetadata
            }
            try Self.validateRelativeFileName(promotion.fileName)
            let (expectedBytes, overflow) = promotion.frameCount.multipliedReportingOverflow(
                by: UInt64(pcmFormat.bytesPerFrame)
            )
            guard !overflow, promotion.dataByteCount == expectedBytes else {
                throw RecordingJournalError.invalidManifest("Promotion byte and frame counts disagree.")
            }
            let segmentSequences = Set(segments.map(\.sequence))
            guard promotion.resolvedRecoveryIssues.allSatisfy({
                $0.segmentSequence >= 0 && segmentSequences.contains($0.segmentSequence)
            }) else {
                throw RecordingJournalError.invalidManifest(
                    "Recovery issues must reference an existing segment sequence."
                )
            }
        }
        if state == .promoted || state == .historyStored || state == .finalized {
            guard promotion != nil else {
                throw RecordingJournalError.missingTransitionMetadata(.promoted)
            }
        }
        if state == .historyStored || state == .finalized {
            guard historyItemID == recordingID else {
                throw RecordingJournalError.missingTransitionMetadata(.historyStored)
            }
        }
    }

    func transitioned(
        to newState: RecordingJournalState,
        promotion requestedPromotion: RecordingPromotion? = nil,
        historyItemID requestedHistoryItemID: UUID? = nil,
        interruptionReason requestedInterruptionReason: RecordingInterruptionReason? = nil,
        now: Date
    ) throws -> RecordingJournalManifest {
        if newState == state {
            if let requestedPromotion, requestedPromotion != promotion {
                throw RecordingJournalError.conflictingTransitionMetadata
            }
            if let requestedHistoryItemID, requestedHistoryItemID != historyItemID {
                throw RecordingJournalError.conflictingTransitionMetadata
            }
            if let requestedInterruptionReason,
               requestedInterruptionReason != interruptionReason {
                throw RecordingJournalError.conflictingTransitionMetadata
            }
            return self
        }

        guard Self.allowedTransitions[state, default: []].contains(newState) else {
            throw RecordingJournalError.invalidStateTransition(from: state, to: newState)
        }

        let (nextGeneration, overflow) = generation.addingReportingOverflow(1)
        guard !overflow else {
            throw RecordingJournalError.invalidManifest(
                "Manifest generation overflow."
            )
        }

        var next = self
        next.state = newState
        next.generation = nextGeneration
        next.updatedAt = now

        switch newState {
        case .promoted:
            guard let requestedPromotion else {
                throw RecordingJournalError.missingTransitionMetadata(.promoted)
            }
            guard requestedPromotion.interruptionReason == interruptionReason,
                  requestedInterruptionReason == nil
                    || requestedInterruptionReason == interruptionReason else {
                throw RecordingJournalError.conflictingTransitionMetadata
            }
            next.promotion = requestedPromotion
        case .historyStored:
            guard promotion != nil, requestedHistoryItemID == recordingID else {
                throw RecordingJournalError.missingTransitionMetadata(.historyStored)
            }
            guard requestedInterruptionReason == nil
                    || requestedInterruptionReason == interruptionReason else {
                throw RecordingJournalError.conflictingTransitionMetadata
            }
            next.historyItemID = requestedHistoryItemID
        case .finalized:
            guard promotion != nil, historyItemID == recordingID else {
                throw RecordingJournalError.missingTransitionMetadata(.finalized)
            }
            guard requestedInterruptionReason == nil
                    || requestedInterruptionReason == interruptionReason else {
                throw RecordingJournalError.conflictingTransitionMetadata
            }
        case .recoverable:
            guard requestedPromotion == nil, requestedHistoryItemID == nil else {
                throw RecordingJournalError.conflictingTransitionMetadata
            }
            if let requestedInterruptionReason {
                guard interruptionReason == nil
                        || interruptionReason == requestedInterruptionReason else {
                    throw RecordingJournalError.conflictingTransitionMetadata
                }
                next.interruptionReason = requestedInterruptionReason
            }
        case .recording, .stopping:
            guard requestedPromotion == nil,
                  requestedHistoryItemID == nil,
                  requestedInterruptionReason == nil else {
                throw RecordingJournalError.conflictingTransitionMetadata
            }
        }

        try next.validate()
        return next
    }

    static func validateRelativeFileName(_ fileName: String) throws {
        guard !fileName.isEmpty,
              fileName != ".",
              fileName != "..",
              fileName != "manifest.json",
              !fileName.hasPrefix("/"),
              !fileName.contains("/"),
              !fileName.contains("\\"),
              URL(fileURLWithPath: fileName).lastPathComponent == fileName else {
            throw RecordingJournalError.unsafeRelativeFileName(fileName)
        }
    }

    private static let allowedTransitions: [RecordingJournalState: Set<RecordingJournalState>] = [
        .recording: [.stopping, .recoverable],
        .stopping: [.recoverable, .promoted],
        .recoverable: [.promoted],
        .promoted: [.historyStored],
        .historyStored: [.finalized],
        .finalized: []
    ]
}

enum RecordingJournalCoding {
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(makeDateFormatter(fractionalSeconds: true).string(from: date))
        }
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = makeDateFormatter(fractionalSeconds: true).date(from: value)
                ?? makeDateFormatter(fractionalSeconds: false).date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO-8601 date: \(value)"
            )
        }
        return decoder
    }

    private static func makeDateFormatter(fractionalSeconds: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = fractionalSeconds
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }
}
