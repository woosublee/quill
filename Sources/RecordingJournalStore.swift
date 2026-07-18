import Darwin
import Foundation

enum RecordingJournalStoreError: Error, Equatable {
    case conflictingExistingRecording(UUID)
    case incompleteExistingRecording(UUID)
    case recordingNotFound(UUID)
    case sourceNotFound(UUID)
    case checkpointRegression
    case invalidCheckpointState(RecordingJournalState)
    case invalidSourceFile
    case systemCall(String, Int32)
}

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

struct RecordingJournalSourceCommit: Equatable {
    let dataByteCount: UInt64
    let frameCount: UInt64
    let firstCommittedFrameOffset: UInt64?
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
    let audioDirectory: URL
    let inflightDirectory: URL

    private let now: () -> Date
    private let lock = NSLock()
    private let fileManager: FileManager

    init(
        audioDirectory: URL,
        now: @escaping () -> Date = Date.init,
        fileManager: FileManager = .default
    ) {
        self.audioDirectory = audioDirectory
        self.inflightDirectory = audioDirectory.appendingPathComponent("inflight", isDirectory: true)
        self.now = now
        self.fileManager = fileManager
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
            try RecordingJournalDurability.syncDirectory(inflightDirectory)
            try createReservedSource(at: session.sourceURL)
            try RecordingJournalDurability.syncDirectory(session.recordingDirectory)

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
            try manifest.validate()
            try writeManifestUnlocked(manifest, to: session.manifestURL)
            return session
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
        try lock.withLock {
            var manifest = try loadManifestUnlocked(recordingID: recordingID)
            guard manifest.state == .recording
                    || manifest.state == .stopping
                    || manifest.state == .recoverable else {
                throw RecordingJournalStoreError.invalidCheckpointState(manifest.state)
            }
            guard let index = manifest.sources.firstIndex(where: { $0.id == sourceID }) else {
                throw RecordingJournalStoreError.sourceNotFound(sourceID)
            }
            let existing = manifest.sources[index]
            let (expectedDataByteCount, overflow) = commit.frameCount.multipliedReportingOverflow(
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
            let resolvedOffset = existing.firstCommittedFrameOffset ?? commit.firstCommittedFrameOffset
            guard commit.dataByteCount == 0 || resolvedOffset != nil else {
                throw RecordingJournalStoreError.checkpointRegression
            }
            guard commit.dataByteCount != existing.committedDataByteCount
                    || resolvedOffset != existing.firstCommittedFrameOffset else {
                return manifest
            }

            manifest.sources[index].committedDataByteCount = commit.dataByteCount
            manifest.sources[index].committedFrameCount = commit.frameCount
            manifest.sources[index].firstCommittedFrameOffset = resolvedOffset
            manifest.generation += 1
            manifest.updatedAt = now()
            try manifest.validate()
            try writeManifestUnlocked(manifest, to: manifestURL(recordingID: recordingID))
            return manifest
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
            throw error
        }
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
        let temporaryURL = targetURL.deletingLastPathComponent()
            .appendingPathComponent(".manifest.\(manifest.generation).\(UUID().uuidString).tmp")
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
