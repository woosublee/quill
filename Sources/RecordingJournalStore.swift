import Darwin
import Foundation

struct RecordingJournalCreateRequest: Equatable {
    var recordingID: UUID
    var sourceID: UUID
    var segmentID: UUID
    var startedAt: Date
    var monotonicAnchorNanoseconds: UInt64
    var sourceMode: RecordingAudioSourceMode
    var sourceKind: RecordingJournalSourceKind
    var sourceFileName: String
    var pipeline: RecordingPipelineSnapshot
}

struct RecordingJournalSession: Equatable {
    let recordingID: UUID
    let sourceID: UUID
    let segmentID: UUID
    let recordingDirectory: URL
    let manifestURL: URL
    let sourceURL: URL
}

struct RecordingJournalSegmentSourceRequest: Equatable {
    let id: UUID
    let kind: RecordingJournalSourceKind
}

struct SegmentedRecordingJournalCreateRequest: Equatable {
    let recordingID: UUID
    let segmentID: UUID
    let startedAt: Date
    let monotonicAnchorNanoseconds: UInt64
    let sources: [RecordingJournalSegmentSourceRequest]
    let pipeline: RecordingPipelineSnapshot
}

struct RecordingJournalSegmentSourceSession: Equatable {
    let kind: RecordingJournalSourceKind
    let session: RecordingJournalSession
}

struct RecordingJournalSegmentSession: Equatable {
    let recordingID: UUID
    let segmentID: UUID
    let sequence: Int
    let recordingDirectory: URL
    let manifestURL: URL
    let sources: [RecordingJournalSegmentSourceSession]
    let creationDisposition: RecordingJournalCreationDisposition
}

struct CombinedRecordingJournalCreateRequest: Equatable {
    var recordingID: UUID
    var microphoneSourceID: UUID
    var systemAudioSourceID: UUID
    var segmentID: UUID
    var startedAt: Date
    var monotonicAnchorNanoseconds: UInt64
    var pipeline: RecordingPipelineSnapshot
}

enum RecordingJournalCreationDisposition: Equatable {
    case created
    case reused
}

struct CombinedRecordingJournalSession: Equatable {
    let recordingID: UUID
    let segmentID: UUID
    let recordingDirectory: URL
    let manifestURL: URL
    let microphoneSession: RecordingJournalSession
    let systemAudioSession: RecordingJournalSession
    let creationDisposition: RecordingJournalCreationDisposition
}

struct RecordingJournalSourceCommit: Equatable {
    let dataByteCount: UInt64
    let frameCount: UInt64
    let firstCommittedFrameOffset: UInt64?
}

struct RecordingJournalManifestWriter {
    let write: (
        _ data: Data,
        _ generation: UInt64,
        _ targetURL: URL,
        _ fileManager: FileManager
    ) throws -> Void

    static let live = RecordingJournalManifestWriter { data, generation, targetURL, fileManager in
        let temporaryURL = targetURL.deletingLastPathComponent()
            .appendingPathComponent(".manifest.\(generation).\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw RecordingJournalStoreError.systemCall("open manifest temp", errno)
        }
        var descriptorOpen = true
        defer {
            if descriptorOpen { Darwin.close(descriptor) }
            try? fileManager.removeItem(at: temporaryURL)
        }

        try RecordingJournalDurability.writeAll(data, to: descriptor)
        try RecordingJournalDurability.fullSync(descriptor)
        guard Darwin.close(descriptor) == 0 else {
            descriptorOpen = false
            throw RecordingJournalStoreError.systemCall("close manifest temp", errno)
        }
        descriptorOpen = false

        guard Darwin.rename(temporaryURL.path, targetURL.path) == 0 else {
            throw RecordingJournalStoreError.systemCall("rename manifest", errno)
        }
        try RecordingJournalDurability.syncDirectory(targetURL.deletingLastPathComponent())
    }
}

enum RecordingCanonicalWAV {
    static let headerByteCount = 44

    static func header(dataByteCount: UInt32) -> Data {
        var data = Data()
        data.appendASCII("RIFF")
        data.appendUInt32LE(36 + dataByteCount)
        data.appendASCII("WAVE")
        data.appendASCII("fmt ")
        data.appendUInt32LE(16)
        data.appendUInt16LE(1)
        data.appendUInt16LE(1)
        data.appendUInt32LE(RecordingPCMFormat.canonical.sampleRate)
        data.appendUInt32LE(
            RecordingPCMFormat.canonical.sampleRate
                * UInt32(RecordingPCMFormat.canonical.bytesPerFrame)
        )
        data.appendUInt16LE(RecordingPCMFormat.canonical.bytesPerFrame)
        data.appendUInt16LE(RecordingPCMFormat.canonical.bitsPerSample)
        data.appendASCII("data")
        data.appendUInt32LE(dataByteCount)
        return data
    }

    static func dataByteCount(in data: Data) -> UInt32? {
        guard data.count >= headerByteCount,
              String(bytes: data[0..<4], encoding: .ascii) == "RIFF",
              String(bytes: data[8..<12], encoding: .ascii) == "WAVE",
              String(bytes: data[12..<16], encoding: .ascii) == "fmt ",
              data.readUInt32LE(at: 16) == 16,
              data.readUInt16LE(at: 20) == 1,
              data.readUInt16LE(at: 22) == RecordingPCMFormat.canonical.channelCount,
              data.readUInt32LE(at: 24) == RecordingPCMFormat.canonical.sampleRate,
              data.readUInt16LE(at: 32) == RecordingPCMFormat.canonical.bytesPerFrame,
              data.readUInt16LE(at: 34) == RecordingPCMFormat.canonical.bitsPerSample,
              String(bytes: data[36..<40], encoding: .ascii) == "data" else {
            return nil
        }
        return data.readUInt32LE(at: 40)
    }

    static func validateFile(at url: URL) throws -> RecordingPromotion {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: headerByteCount) ?? Data()
        guard let declaredDataBytes = dataByteCount(in: header) else {
            throw RecordingJournalStoreError.invalidSourceFile
        }
        let physicalSize = try RecordingJournalDurability.fileSize(at: url)
        guard physicalSize >= UInt64(headerByteCount),
              physicalSize - UInt64(headerByteCount) == UInt64(declaredDataBytes),
              declaredDataBytes > 0,
              declaredDataBytes % UInt32(RecordingPCMFormat.canonical.bytesPerFrame) == 0 else {
            throw RecordingJournalStoreError.invalidSourceFile
        }
        return RecordingPromotion(
            fileName: url.lastPathComponent,
            dataByteCount: UInt64(declaredDataBytes),
            frameCount: UInt64(declaredDataBytes) / UInt64(RecordingPCMFormat.canonical.bytesPerFrame)
        )
    }
}

final class RecordingJournalStore {
    static let discardMarkerFileName = ".discarded"

    let audioDirectory: URL
    let inflightDirectory: URL

    private let now: () -> Date
    private let lock = NSLock()
    private let fileManager: FileManager
    private let manifestWriter: RecordingJournalManifestWriter

    init(
        audioDirectory: URL,
        now: @escaping () -> Date = Date.init,
        fileManager: FileManager = .default,
        manifestWriter: RecordingJournalManifestWriter = .live
    ) {
        self.audioDirectory = audioDirectory
        self.inflightDirectory = audioDirectory.appendingPathComponent("inflight", isDirectory: true)
        self.now = now
        self.fileManager = fileManager
        self.manifestWriter = manifestWriter
    }

    func createSingleSource(
        _ request: RecordingJournalCreateRequest
    ) throws -> RecordingJournalSession {
        try lock.withLock {
            try RecordingJournalManifest.validateRelativeFileName(request.sourceFileName)
            try ensureDirectory(audioDirectory, permissions: 0o700)
            try ensureDirectory(inflightDirectory, permissions: 0o700)
            let session = session(
                recordingID: request.recordingID,
                sourceID: request.sourceID,
                segmentID: request.segmentID,
                sourceFileName: request.sourceFileName
            )

            if fileManager.fileExists(atPath: session.manifestURL.path) {
                let manifest = try loadManifestUnlocked(recordingID: request.recordingID)
                guard manifestMatchesRequest(manifest, request: request) else {
                    throw RecordingJournalStoreError.conflictingExistingRecording(request.recordingID)
                }
                guard fileManager.fileExists(atPath: session.sourceURL.path) else {
                    throw RecordingJournalStoreError.incompleteExistingRecording(request.recordingID)
                }
                return session
            }
            if fileManager.fileExists(atPath: session.recordingDirectory.path) {
                throw RecordingJournalStoreError.incompleteExistingRecording(request.recordingID)
            }

            try ensureDirectory(session.recordingDirectory, permissions: 0o700)
            do {
                try RecordingJournalDurability.syncDirectory(inflightDirectory)
                try createReservedSource(at: session.sourceURL)
                try RecordingJournalDurability.syncDirectory(session.recordingDirectory)
            } catch {
                try? fileManager.removeItem(at: session.recordingDirectory)
                try? RecordingJournalDurability.syncDirectory(inflightDirectory)
                throw error
            }

            let source = RecordingJournalSource(
                id: request.sourceID,
                kind: request.sourceKind,
                fileName: request.sourceFileName,
                storageLayout: .reservedWAVHeader44,
                committedDataByteCount: 0,
                committedFrameCount: 0,
                firstCommittedFrameOffset: nil,
                segmentID: request.segmentID
            )
            let manifest = RecordingJournalManifest(
                schemaVersion: 1,
                generation: 1,
                recordingID: request.recordingID,
                startedAt: request.startedAt,
                updatedAt: now(),
                monotonicAnchorNanoseconds: request.monotonicAnchorNanoseconds,
                state: .recording,
                sourceMode: request.sourceMode,
                pcmFormat: .canonical,
                sources: [source],
                segments: [RecordingJournalSegment(
                    id: request.segmentID,
                    sequence: 0,
                    sourceIDs: [request.sourceID]
                )],
                pipeline: request.pipeline,
                promotion: nil,
                historyItemID: nil
            )
            do {
                try manifest.validate()
                try writeManifestUnlocked(manifest, to: session.manifestURL)
                return session
            } catch {
                try? fileManager.removeItem(at: session.recordingDirectory)
                try? RecordingJournalDurability.syncDirectory(inflightDirectory)
                throw error
            }
        }
    }

    func createCombined(
        _ request: CombinedRecordingJournalCreateRequest
    ) throws -> CombinedRecordingJournalSession {
        try lock.withLock {
            try ensureDirectory(audioDirectory, permissions: 0o700)
            try ensureDirectory(inflightDirectory, permissions: 0o700)
            let createdSession = combinedSession(
                request: request,
                creationDisposition: .created
            )

            if fileManager.fileExists(atPath: createdSession.manifestURL.path) {
                let combinedSession = combinedSession(
                    request: request,
                    creationDisposition: .reused
                )
                let manifest = try loadManifestUnlocked(
                    recordingID: request.recordingID
                )
                guard manifestMatchesCombinedRequest(
                    manifest,
                    request: request
                ) else {
                    throw RecordingJournalStoreError.conflictingExistingRecording(
                        request.recordingID
                    )
                }
                guard fileManager.fileExists(
                        atPath: combinedSession.microphoneSession.sourceURL.path
                    ),
                    fileManager.fileExists(
                        atPath: combinedSession.systemAudioSession.sourceURL.path
                    ) else {
                    throw RecordingJournalStoreError.incompleteExistingRecording(
                        request.recordingID
                    )
                }
                return combinedSession
            }
            let combinedSession = createdSession
            if fileManager.fileExists(
                atPath: combinedSession.recordingDirectory.path
            ) {
                throw RecordingJournalStoreError.incompleteExistingRecording(
                    request.recordingID
                )
            }

            try ensureDirectory(
                combinedSession.recordingDirectory,
                permissions: 0o700
            )
            do {
                try RecordingJournalDurability.syncDirectory(inflightDirectory)
                try createReservedSource(
                    at: combinedSession.microphoneSession.sourceURL
                )
                try createReservedSource(
                    at: combinedSession.systemAudioSession.sourceURL
                )
                try RecordingJournalDurability.syncDirectory(
                    combinedSession.recordingDirectory
                )

                let microphoneSource = RecordingJournalSource(
                    id: request.microphoneSourceID,
                    kind: .microphone,
                    fileName: "microphone.wav.part",
                    storageLayout: .reservedWAVHeader44,
                    committedDataByteCount: 0,
                    committedFrameCount: 0,
                    firstCommittedFrameOffset: nil,
                    segmentID: request.segmentID
                )
                let systemAudioSource = RecordingJournalSource(
                    id: request.systemAudioSourceID,
                    kind: .systemAudio,
                    fileName: "system-audio.wav.part",
                    storageLayout: .reservedWAVHeader44,
                    committedDataByteCount: 0,
                    committedFrameCount: 0,
                    firstCommittedFrameOffset: nil,
                    segmentID: request.segmentID
                )
                let manifest = RecordingJournalManifest(
                    schemaVersion: 1,
                    generation: 1,
                    recordingID: request.recordingID,
                    startedAt: request.startedAt,
                    updatedAt: now(),
                    monotonicAnchorNanoseconds:
                        request.monotonicAnchorNanoseconds,
                    state: .recording,
                    sourceMode: .combined,
                    pcmFormat: .canonical,
                    sources: [microphoneSource, systemAudioSource],
                    segments: [RecordingJournalSegment(
                        id: request.segmentID,
                        sequence: 0,
                        sourceIDs: [
                            request.microphoneSourceID,
                            request.systemAudioSourceID
                        ]
                    )],
                    pipeline: request.pipeline,
                    promotion: nil,
                    historyItemID: nil
                )
                try manifest.validate()
                try writeManifestUnlocked(
                    manifest,
                    to: combinedSession.manifestURL
                )
                return combinedSession
            } catch {
                try? fileManager.removeItem(
                    at: combinedSession.recordingDirectory
                )
                try? RecordingJournalDurability.syncDirectory(
                    inflightDirectory
                )
                throw error
            }
        }
    }

    func createSegmented(
        _ request: SegmentedRecordingJournalCreateRequest
    ) throws -> RecordingJournalSegmentSession {
        try lock.withLock {
            try validateSegmentSources(request.sources)
            try ensureDirectory(audioDirectory, permissions: 0o700)
            try ensureDirectory(inflightDirectory, permissions: 0o700)
            let createdSession = segmentedSession(
                recordingID: request.recordingID,
                segmentID: request.segmentID,
                sequence: 0,
                sources: request.sources,
                creationDisposition: .created
            )

            if fileManager.fileExists(atPath: createdSession.manifestURL.path) {
                let manifest = try loadManifestUnlocked(
                    recordingID: request.recordingID
                )
                guard manifestMatchesSegmentedCreateRequest(
                    manifest,
                    request: request
                ) else {
                    throw RecordingJournalStoreError.conflictingExistingRecording(
                        request.recordingID
                    )
                }
                return try validatedReusableSegmentSession(
                    createdSession,
                    manifest: manifest
                )
            }
            if fileManager.fileExists(atPath: createdSession.recordingDirectory.path) {
                throw RecordingJournalStoreError.incompleteExistingRecording(
                    request.recordingID
                )
            }

            try ensureDirectory(createdSession.recordingDirectory, permissions: 0o700)
            var createdURLs: [URL] = []
            do {
                try RecordingJournalDurability.syncDirectory(inflightDirectory)
                for source in createdSession.sources {
                    try createReservedSource(at: source.session.sourceURL)
                    createdURLs.append(source.session.sourceURL)
                }
                try RecordingJournalDurability.syncDirectory(
                    createdSession.recordingDirectory
                )
                let manifest = RecordingJournalManifest(
                    schemaVersion: 1,
                    generation: 1,
                    recordingID: request.recordingID,
                    startedAt: request.startedAt,
                    updatedAt: now(),
                    monotonicAnchorNanoseconds:
                        request.monotonicAnchorNanoseconds,
                    state: .recording,
                    sourceMode: .segmented,
                    pcmFormat: .canonical,
                    sources: zip(request.sources, createdSession.sources).map {
                        sourceRequest, sourceSession in
                        RecordingJournalSource(
                            id: sourceRequest.id,
                            kind: sourceRequest.kind,
                            fileName: sourceSession.session.sourceURL.lastPathComponent,
                            storageLayout: .reservedWAVHeader44,
                            committedDataByteCount: 0,
                            committedFrameCount: 0,
                            firstCommittedFrameOffset: nil,
                            segmentID: request.segmentID
                        )
                    },
                    segments: [RecordingJournalSegment(
                        id: request.segmentID,
                        sequence: 0,
                        sourceIDs: request.sources.map(\.id)
                    )],
                    pipeline: request.pipeline,
                    promotion: nil,
                    historyItemID: nil
                )
                try manifest.validate()
                try writeManifestUnlocked(manifest, to: createdSession.manifestURL)
                return createdSession
            } catch {
                for url in createdURLs {
                    try? fileManager.removeItem(at: url)
                }
                try? fileManager.removeItem(at: createdSession.recordingDirectory)
                try? RecordingJournalDurability.syncDirectory(inflightDirectory)
                throw error
            }
        }
    }

    func appendSegment(
        recordingID: UUID,
        segmentID: UUID,
        sequence: Int,
        sources: [RecordingJournalSegmentSourceRequest]
    ) throws -> RecordingJournalSegmentSession {
        try lock.withLock {
            try validateSegmentSources(sources)
            var manifest = try loadManifestUnlocked(recordingID: recordingID)
            guard manifest.sourceMode == .segmented else {
                throw RecordingJournalStoreError.conflictingExistingRecording(
                    recordingID
                )
            }
            guard manifest.state == .recording else {
                throw RecordingJournalStoreError.invalidCheckpointState(manifest.state)
            }

            if let existingSegment = manifest.segments.first(where: {
                $0.sequence == sequence || $0.id == segmentID
            }) {
                guard existingSegment.sequence == sequence,
                      existingSegment.id == segmentID else {
                    throw RecordingJournalStoreError.conflictingExistingSegment(
                        segmentID
                    )
                }
                let requestedSourceIDs = sources.map(\.id)
                guard existingSegment.sourceIDs == requestedSourceIDs,
                      sources.allSatisfy({ request in
                          manifest.sources.contains(where: {
                              $0.id == request.id
                                  && $0.kind == request.kind
                                  && $0.segmentID == segmentID
                                  && $0.fileName == segmentedSourceFileName(
                                      sequence: sequence,
                                      kind: request.kind
                                  )
                          })
                      }) else {
                    throw RecordingJournalStoreError.conflictingExistingSegment(
                        segmentID
                    )
                }
                let reused = segmentedSession(
                    recordingID: recordingID,
                    segmentID: segmentID,
                    sequence: sequence,
                    sources: sources,
                    creationDisposition: .reused
                )
                return try validatedReusableSegmentSession(
                    reused,
                    manifest: manifest
                )
            }

            let expectedSequence = manifest.segments.count
            guard sequence == expectedSequence else {
                throw RecordingJournalStoreError.invalidSegmentSequence(
                    expected: expectedSequence,
                    actual: sequence
                )
            }
            let newSession = segmentedSession(
                recordingID: recordingID,
                segmentID: segmentID,
                sequence: sequence,
                sources: sources,
                creationDisposition: .created
            )
            var createdURLs: [URL] = []
            do {
                for source in newSession.sources {
                    let sourceURL = source.session.sourceURL
                    if fileManager.fileExists(atPath: sourceURL.path) {
                        guard try isEmptyReservedSource(at: sourceURL) else {
                            throw RecordingJournalStoreError.incompleteExistingRecording(
                                recordingID
                            )
                        }
                    } else {
                        try createReservedSource(at: sourceURL)
                        createdURLs.append(sourceURL)
                    }
                }
                try RecordingJournalDurability.syncDirectory(
                    newSession.recordingDirectory
                )
                let newSources = zip(sources, newSession.sources).map {
                    request, sourceSession in
                    RecordingJournalSource(
                        id: request.id,
                        kind: request.kind,
                        fileName: sourceSession.session.sourceURL.lastPathComponent,
                        storageLayout: .reservedWAVHeader44,
                        committedDataByteCount: 0,
                        committedFrameCount: 0,
                        firstCommittedFrameOffset: nil,
                        segmentID: segmentID
                    )
                }
                let (nextGeneration, overflow) =
                    manifest.generation.addingReportingOverflow(1)
                guard !overflow else {
                    throw RecordingJournalError.invalidManifest(
                        "Manifest generation overflow."
                    )
                }
                manifest.sources.append(contentsOf: newSources)
                manifest.segments.append(RecordingJournalSegment(
                    id: segmentID,
                    sequence: sequence,
                    sourceIDs: sources.map(\.id)
                ))
                manifest.generation = nextGeneration
                manifest.updatedAt = now()
                try manifest.validate()
                try writeManifestUnlocked(manifest, to: newSession.manifestURL)
                return newSession
            } catch {
                for url in createdURLs {
                    try? fileManager.removeItem(at: url)
                }
                if !createdURLs.isEmpty {
                    try? RecordingJournalDurability.syncDirectory(
                        newSession.recordingDirectory
                    )
                }
                throw error
            }
        }
    }

    func loadManifest(recordingID: UUID) throws -> RecordingJournalManifest {
        try lock.withLock {
            try loadManifestUnlocked(recordingID: recordingID)
        }
    }

    func recordCheckpoint(
        recordingID: UUID,
        sourceID: UUID,
        commit: RecordingJournalSourceCommit
    ) throws -> RecordingJournalManifest {
        try recordCheckpoints(
            recordingID: recordingID,
            commitsBySourceID: [sourceID: commit]
        )
    }

    func recordCheckpoints(
        recordingID: UUID,
        commitsBySourceID: [UUID: RecordingJournalSourceCommit]
    ) throws -> RecordingJournalManifest {
        try lock.withLock {
            var manifest = try loadManifestUnlocked(recordingID: recordingID)
            guard manifest.state == .recording
                    || manifest.state == .stopping
                    || manifest.state == .recoverable else {
                throw RecordingJournalStoreError.invalidCheckpointState(
                    manifest.state
                )
            }

            let changedUpdates = try validatedCheckpointUpdates(
                commitsBySourceID,
                in: manifest
            )
            guard !changedUpdates.isEmpty else { return manifest }

            let (nextGeneration, generationOverflow) =
                manifest.generation.addingReportingOverflow(1)
            guard !generationOverflow else {
                throw RecordingJournalError.invalidManifest(
                    "Manifest generation overflow."
                )
            }

            for (index, commit) in changedUpdates {
                manifest.sources[index].committedDataByteCount =
                    commit.dataByteCount
                manifest.sources[index].committedFrameCount =
                    commit.frameCount
                manifest.sources[index].firstCommittedFrameOffset =
                    commit.firstCommittedFrameOffset
            }
            manifest.generation = nextGeneration
            manifest.updatedAt = now()
            try manifest.validate()
            try writeManifestUnlocked(
                manifest,
                to: manifestURL(recordingID: recordingID)
            )
            return manifest
        }
    }

    func markRecoverableAfterPersistenceFailure(
        recordingID: UUID,
        commitsBySourceID: [UUID: RecordingJournalSourceCommit],
        interruptionReason: RecordingInterruptionReason
    ) throws -> RecordingJournalManifest {
        try lock.withLock {
            let manifest = try loadManifestUnlocked(recordingID: recordingID)
            guard manifest.state == .recording
                    || manifest.state == .stopping
                    || manifest.state == .recoverable else {
                throw RecordingJournalStoreError.invalidCheckpointState(
                    manifest.state
                )
            }

            let updates = try validatedCheckpointUpdates(
                commitsBySourceID,
                in: manifest
            )
            let current = manifest
            var next = try current.transitioned(
                to: .recoverable,
                interruptionReason: interruptionReason,
                now: now()
            )
            for (index, commit) in updates {
                next.sources[index].committedDataByteCount = commit.dataByteCount
                next.sources[index].committedFrameCount = commit.frameCount
                next.sources[index].firstCommittedFrameOffset = commit.firstCommittedFrameOffset
            }
            if next.state == current.state, next != current {
                let (nextGeneration, overflow) = current.generation.addingReportingOverflow(1)
                guard !overflow else {
                    throw RecordingJournalError.invalidManifest(
                        "Manifest generation overflow."
                    )
                }
                next.generation = nextGeneration
                next.updatedAt = now()
            }
            guard next != current else { return current }
            try next.validate()
            try writeManifestUnlocked(next, to: manifestURL(recordingID: recordingID))
            return next
        }
    }

    func transition(
        recordingID: UUID,
        to state: RecordingJournalState,
        promotion: RecordingPromotion? = nil,
        historyItemID: UUID? = nil
    ) throws -> RecordingJournalManifest {
        try lock.withLock {
            let current = try loadManifestUnlocked(recordingID: recordingID)
            let next = try current.transitioned(
                to: state,
                promotion: promotion,
                historyItemID: historyItemID,
                now: now()
            )
            guard next != current else { return current }
            try writeManifestUnlocked(next, to: manifestURL(recordingID: recordingID))
            return next
        }
    }

    func recordingDirectory(recordingID: UUID) -> URL {
        inflightDirectory
            .appendingPathComponent(recordingID.uuidString.lowercased(), isDirectory: true)
    }

    func manifestURL(recordingID: UUID) -> URL {
        recordingDirectory(recordingID: recordingID).appendingPathComponent("manifest.json")
    }

    func sourceURL(recordingID: UUID, fileName: String) throws -> URL {
        try RecordingJournalManifest.validateRelativeFileName(fileName)
        return recordingDirectory(recordingID: recordingID).appendingPathComponent(fileName)
    }

    func permanentURL(recordingID: UUID) -> URL {
        audioDirectory.appendingPathComponent(recordingID.uuidString.lowercased() + ".wav")
    }

    func markDiscarded(recordingID: UUID) throws {
        try lock.withLock {
            let directory = recordingDirectory(recordingID: recordingID)
            guard fileManager.fileExists(atPath: directory.path) else { return }
            let markerURL = directory.appendingPathComponent(
                Self.discardMarkerFileName
            )
            if fileManager.fileExists(atPath: markerURL.path) {
                return
            }

            let descriptor = Darwin.open(
                markerURL.path,
                O_WRONLY | O_CREAT | O_EXCL,
                mode_t(0o600)
            )
            guard descriptor >= 0 else {
                throw RecordingJournalStoreError.systemCall(
                    "open discard marker",
                    errno
                )
            }
            var descriptorOpen = true
            defer {
                if descriptorOpen { Darwin.close(descriptor) }
            }
            try RecordingJournalDurability.fullSync(descriptor)
            guard Darwin.close(descriptor) == 0 else {
                descriptorOpen = false
                throw RecordingJournalStoreError.systemCall(
                    "close discard marker",
                    errno
                )
            }
            descriptorOpen = false
            try RecordingJournalDurability.syncDirectory(directory)
        }
    }

    func discardInflightRecording(recordingID: UUID) throws {
        try lock.withLock {
            let directory = recordingDirectory(recordingID: recordingID)
            let tombstone = inflightDirectory.appendingPathComponent(
                ".discarded-\(recordingID.uuidString.lowercased())",
                isDirectory: true
            )

            if fileManager.fileExists(atPath: directory.path) {
                guard !fileManager.fileExists(atPath: tombstone.path) else {
                    throw RecordingJournalStoreError.conflictingExistingRecording(
                        recordingID
                    )
                }
                guard Darwin.rename(directory.path, tombstone.path) == 0 else {
                    throw RecordingJournalStoreError.systemCall(
                        "rename discarded recording",
                        errno
                    )
                }
                try RecordingJournalDurability.syncDirectory(
                    inflightDirectory
                )
            }

            guard fileManager.fileExists(atPath: tombstone.path) else {
                return
            }
            try fileManager.removeItem(at: tombstone)
            try RecordingJournalDurability.syncDirectory(inflightDirectory)
        }
    }

    func removeInflightRecording(recordingID: UUID) throws {
        try lock.withLock {
            let directory = recordingDirectory(recordingID: recordingID)
            guard fileManager.fileExists(atPath: directory.path) else { return }
            try fileManager.removeItem(at: directory)
            if fileManager.fileExists(atPath: inflightDirectory.path) {
                try RecordingJournalDurability.syncDirectory(inflightDirectory)
            }
        }
    }

    private func session(
        recordingID: UUID,
        sourceID: UUID,
        segmentID: UUID,
        sourceFileName: String
    ) -> RecordingJournalSession {
        let directory = recordingDirectory(recordingID: recordingID)
        return RecordingJournalSession(
            recordingID: recordingID,
            sourceID: sourceID,
            segmentID: segmentID,
            recordingDirectory: directory,
            manifestURL: directory.appendingPathComponent("manifest.json"),
            sourceURL: directory.appendingPathComponent(sourceFileName)
        )
    }

    private func segmentedSession(
        recordingID: UUID,
        segmentID: UUID,
        sequence: Int,
        sources: [RecordingJournalSegmentSourceRequest],
        creationDisposition: RecordingJournalCreationDisposition
    ) -> RecordingJournalSegmentSession {
        let sourceSessions = sources.map { source in
            RecordingJournalSegmentSourceSession(
                kind: source.kind,
                session: session(
                    recordingID: recordingID,
                    sourceID: source.id,
                    segmentID: segmentID,
                    sourceFileName: segmentedSourceFileName(
                        sequence: sequence,
                        kind: source.kind
                    )
                )
            )
        }
        let directory = recordingDirectory(recordingID: recordingID)
        return RecordingJournalSegmentSession(
            recordingID: recordingID,
            segmentID: segmentID,
            sequence: sequence,
            recordingDirectory: directory,
            manifestURL: directory.appendingPathComponent("manifest.json"),
            sources: sourceSessions,
            creationDisposition: creationDisposition
        )
    }

    private func segmentedSourceFileName(
        sequence: Int,
        kind: RecordingJournalSourceKind
    ) -> String {
        let kindName = switch kind {
        case .microphone: "microphone"
        case .systemAudio: "system-audio"
        }
        return String(format: "segment-%04d-%@.wav.part", sequence, kindName)
    }

    private func validateSegmentSources(
        _ sources: [RecordingJournalSegmentSourceRequest]
    ) throws {
        guard (1...2).contains(sources.count),
              Set(sources.map(\.id)).count == sources.count,
              Set(sources.map(\.kind)).count == sources.count else {
            throw RecordingJournalStoreError.invalidSegmentSourceShape
        }
    }

    private func isEmptyReservedSource(at url: URL) throws -> Bool {
        let size = try RecordingJournalDurability.fileSize(at: url)
        guard size == UInt64(RecordingCanonicalWAV.headerByteCount) else {
            return false
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: RecordingCanonicalWAV.headerByteCount)
            ?? Data()
        return RecordingCanonicalWAV.dataByteCount(in: header) == 0
    }

    private func validatedReusableSegmentSession(
        _ session: RecordingJournalSegmentSession,
        manifest: RecordingJournalManifest
    ) throws -> RecordingJournalSegmentSession {
        guard session.sources.allSatisfy({ source in
            fileManager.fileExists(atPath: source.session.sourceURL.path)
                && manifest.sources.contains(where: {
                    $0.id == source.session.sourceID
                        && $0.kind == source.kind
                        && $0.segmentID == session.segmentID
                        && $0.fileName
                            == source.session.sourceURL.lastPathComponent
                })
        }) else {
            throw RecordingJournalStoreError.incompleteExistingRecording(
                session.recordingID
            )
        }
        return RecordingJournalSegmentSession(
            recordingID: session.recordingID,
            segmentID: session.segmentID,
            sequence: session.sequence,
            recordingDirectory: session.recordingDirectory,
            manifestURL: session.manifestURL,
            sources: session.sources,
            creationDisposition: .reused
        )
    }

    private func combinedSession(
        request: CombinedRecordingJournalCreateRequest,
        creationDisposition: RecordingJournalCreationDisposition
    ) -> CombinedRecordingJournalSession {
        let microphoneSession = session(
            recordingID: request.recordingID,
            sourceID: request.microphoneSourceID,
            segmentID: request.segmentID,
            sourceFileName: "microphone.wav.part"
        )
        let systemAudioSession = session(
            recordingID: request.recordingID,
            sourceID: request.systemAudioSourceID,
            segmentID: request.segmentID,
            sourceFileName: "system-audio.wav.part"
        )
        return CombinedRecordingJournalSession(
            recordingID: request.recordingID,
            segmentID: request.segmentID,
            recordingDirectory: microphoneSession.recordingDirectory,
            manifestURL: microphoneSession.manifestURL,
            microphoneSession: microphoneSession,
            systemAudioSession: systemAudioSession,
            creationDisposition: creationDisposition
        )
    }

    private func ensureDirectory(_ url: URL, permissions: Int) throws {
        if !fileManager.fileExists(atPath: url.path) {
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: permissions]
            )
        }
    }

    private func createReservedSource(at url: URL) throws {
        let descriptor = Darwin.open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw RecordingJournalStoreError.systemCall("open", errno)
        }
        var shouldClose = true
        defer {
            if shouldClose { Darwin.close(descriptor) }
        }
        do {
            try RecordingJournalDurability.writeAll(
                RecordingCanonicalWAV.header(dataByteCount: 0),
                to: descriptor
            )
            try RecordingJournalDurability.fullSync(descriptor)
            guard Darwin.close(descriptor) == 0 else {
                shouldClose = false
                throw RecordingJournalStoreError.systemCall("close", errno)
            }
            shouldClose = false
        } catch {
            try? fileManager.removeItem(at: url)
            throw error
        }
    }

    private func validatedCheckpointUpdates(
        _ commitsBySourceID: [UUID: RecordingJournalSourceCommit],
        in manifest: RecordingJournalManifest
    ) throws -> [Int: RecordingJournalSourceCommit] {
        var updates: [Int: RecordingJournalSourceCommit] = [:]
        for (sourceID, commit) in commitsBySourceID {
            guard let index = manifest.sources.firstIndex(where: {
                $0.id == sourceID
            }) else {
                throw RecordingJournalStoreError.sourceNotFound(sourceID)
            }
            let existing = manifest.sources[index]
            let (expectedDataByteCount, overflow) =
                commit.frameCount.multipliedReportingOverflow(
                    by: UInt64(manifest.pcmFormat.bytesPerFrame)
                )
            guard !overflow,
                  commit.dataByteCount == expectedDataByteCount,
                  commit.dataByteCount >= existing.committedDataByteCount,
                  commit.frameCount >= existing.committedFrameCount else {
                throw RecordingJournalStoreError.checkpointRegression
            }
            if let existingOffset = existing.firstCommittedFrameOffset,
               let requestedOffset = commit.firstCommittedFrameOffset,
               existingOffset != requestedOffset {
                throw RecordingJournalStoreError.checkpointRegression
            }
            let resolvedOffset = existing.firstCommittedFrameOffset
                ?? commit.firstCommittedFrameOffset
            guard commit.dataByteCount == 0 || resolvedOffset != nil else {
                throw RecordingJournalStoreError.checkpointRegression
            }
            let resolvedCommit = RecordingJournalSourceCommit(
                dataByteCount: commit.dataByteCount,
                frameCount: commit.frameCount,
                firstCommittedFrameOffset: resolvedOffset
            )
            if resolvedCommit.dataByteCount != existing.committedDataByteCount
                || resolvedCommit.frameCount != existing.committedFrameCount
                || resolvedCommit.firstCommittedFrameOffset
                    != existing.firstCommittedFrameOffset {
                updates[index] = resolvedCommit
            }
        }
        return updates
    }

    private func loadManifestUnlocked(recordingID: UUID) throws -> RecordingJournalManifest {
        let url = manifestURL(recordingID: recordingID)
        guard fileManager.fileExists(atPath: url.path) else {
            throw RecordingJournalStoreError.recordingNotFound(recordingID)
        }
        let data = try Data(contentsOf: url)
        let manifest = try RecordingJournalCoding.makeDecoder().decode(
            RecordingJournalManifest.self,
            from: data
        )
        guard manifest.recordingID == recordingID else {
            throw RecordingJournalError.invalidManifest("Manifest recording ID does not match its directory.")
        }
        try manifest.validate()
        return manifest
    }

    private func writeManifestUnlocked(
        _ manifest: RecordingJournalManifest,
        to targetURL: URL
    ) throws {
        let data = try RecordingJournalCoding.makeEncoder().encode(manifest)
        try manifestWriter.write(
            data,
            manifest.generation,
            targetURL,
            fileManager
        )
    }

    private func manifestMatchesSegmentedCreateRequest(
        _ manifest: RecordingJournalManifest,
        request: SegmentedRecordingJournalCreateRequest
    ) -> Bool {
        guard manifest.recordingID == request.recordingID,
              manifest.startedAt == request.startedAt,
              manifest.monotonicAnchorNanoseconds
                == request.monotonicAnchorNanoseconds,
              manifest.sourceMode == .segmented,
              manifest.pipeline == request.pipeline,
              manifest.segments.count == 1,
              manifest.sources.count == request.sources.count else {
            return false
        }
        let segment = manifest.segments[0]
        guard segment.id == request.segmentID,
              segment.sequence == 0,
              segment.sourceIDs == request.sources.map(\.id) else {
            return false
        }
        return request.sources.allSatisfy { requested in
            manifest.sources.contains(where: {
                $0.id == requested.id
                    && $0.kind == requested.kind
                    && $0.segmentID == request.segmentID
                    && $0.fileName == segmentedSourceFileName(
                        sequence: 0,
                        kind: requested.kind
                    )
            })
        }
    }

    private func manifestMatchesCombinedRequest(
        _ manifest: RecordingJournalManifest,
        request: CombinedRecordingJournalCreateRequest
    ) -> Bool {
        guard manifest.recordingID == request.recordingID,
              manifest.startedAt == request.startedAt,
              manifest.monotonicAnchorNanoseconds
                == request.monotonicAnchorNanoseconds,
              manifest.sourceMode == .combined,
              manifest.pipeline == request.pipeline,
              manifest.sources.count == 2,
              manifest.segments.count == 1 else {
            return false
        }
        let segment = manifest.segments[0]
        guard segment.id == request.segmentID,
              segment.sequence == 0,
              Set(segment.sourceIDs) == Set([
                request.microphoneSourceID,
                request.systemAudioSourceID
              ]) else {
            return false
        }
        let microphoneSource = manifest.sources.first(where: {
            $0.kind == .microphone
        })
        let systemAudioSource = manifest.sources.first(where: {
            $0.kind == .systemAudio
        })
        return microphoneSource?.id == request.microphoneSourceID
            && microphoneSource?.fileName == "microphone.wav.part"
            && microphoneSource?.segmentID == request.segmentID
            && systemAudioSource?.id == request.systemAudioSourceID
            && systemAudioSource?.fileName == "system-audio.wav.part"
            && systemAudioSource?.segmentID == request.segmentID
    }

    private func manifestMatchesRequest(
        _ manifest: RecordingJournalManifest,
        request: RecordingJournalCreateRequest
    ) -> Bool {
        guard manifest.recordingID == request.recordingID,
              manifest.startedAt == request.startedAt,
              manifest.monotonicAnchorNanoseconds == request.monotonicAnchorNanoseconds,
              manifest.sourceMode == request.sourceMode,
              manifest.pipeline == request.pipeline,
              manifest.sources.count == 1,
              manifest.segments.count == 1 else {
            return false
        }
        let source = manifest.sources[0]
        let segment = manifest.segments[0]
        return source.id == request.sourceID
            && source.kind == request.sourceKind
            && source.fileName == request.sourceFileName
            && source.segmentID == request.segmentID
            && segment.id == request.segmentID
            && segment.sequence == 0
            && segment.sourceIDs == [request.sourceID]
    }
}

enum RecordingJournalDurability {
    static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
                guard written >= 0 else {
                    if errno == EINTR { continue }
                    throw RecordingJournalStoreError.systemCall("write", errno)
                }
                guard written > 0 else {
                    throw RecordingJournalStoreError.systemCall("write zero bytes", EIO)
                }
                offset += written
            }
        }
    }

    static func fullSync(_ descriptor: Int32) throws {
        if Darwin.fcntl(descriptor, F_FULLFSYNC) == 0 { return }
        let fullSyncError = errno
        if Darwin.fsync(descriptor) == 0 { return }
        throw RecordingJournalStoreError.systemCall(
            "F_FULLFSYNC(\(fullSyncError))/fsync",
            errno
        )
    }

    static func syncDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw RecordingJournalStoreError.systemCall("open directory", errno)
        }
        defer { Darwin.close(descriptor) }
        if Darwin.fsync(descriptor) != 0, errno != EINVAL {
            throw RecordingJournalStoreError.systemCall("fsync directory", errno)
        }
    }

    static func fileSize(at url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let number = attributes[.size] as? NSNumber else {
            throw RecordingJournalStoreError.invalidSourceFile
        }
        return number.uint64Value
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

private extension Data {
    mutating func appendASCII(_ value: String) {
        append(contentsOf: value.utf8)
    }

    mutating func appendUInt16LE(_ value: UInt16) {
        append(UInt8(value & 0x00ff))
        append(UInt8((value & 0xff00) >> 8))
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(value & 0x000000ff))
        append(UInt8((value & 0x0000ff00) >> 8))
        append(UInt8((value & 0x00ff0000) >> 16))
        append(UInt8((value & 0xff000000) >> 24))
    }

    func readUInt16LE(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func readUInt32LE(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }
}
