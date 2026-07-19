import Foundation

enum CloudTranscriptionJobPhase: String, Codable, Equatable, Sendable {
    case prepared
    case transcribing
    case interrupted
    case failed
    case assembled
}

struct CloudTranscriptionCompletedChunk: Codable, Equatable, Sendable {
    let index: Int
    let normalizedRawText: String
}

struct CloudTranscriptionStoredFailure: Codable, Equatable, Sendable {
    let category: CloudTranscriptionFailureCategory
    let httpStatus: Int?
    let retryAfterSeconds: TimeInterval?
}

struct CloudTranscriptionCompletionPolicy: Codable, Equatable, Sendable {
    let postProcessingEnabled: Bool
    let preserveExactWording: Bool
    let outputLanguage: String
    let pressEnterCommandEnabled: Bool
}

enum CloudTranscriptionJobValidationError: Error, Equatable {
    case unsupportedSchemaVersion(Int)
    case historyIDMismatch
    case unsafeAudioFileName
    case invalidSourceIdentity
    case sourcePlanMismatch
    case identityPlanMismatch
    case invalidPlan
    case invalidCompletedChunkPrefix
    case firstIncompleteChunkIndexMismatch
    case assembledBeforeComplete
}

struct CloudTranscriptionJobRecord: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let historyID: UUID
    let createdAt: Date
    var updatedAt: Date
    var phase: CloudTranscriptionJobPhase
    let identity: CloudTranscriptionJobIdentity
    let plan: CloudTranscriptionChunkPlan
    var completedChunks: [CloudTranscriptionCompletedChunk]
    var firstIncompleteChunkIndex: Int
    var lastFailure: CloudTranscriptionStoredFailure?
    let completionPolicy: CloudTranscriptionCompletionPolicy

    func validate(fileNameID: UUID) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw CloudTranscriptionJobValidationError.unsupportedSchemaVersion(
                schemaVersion
            )
        }
        guard historyID == fileNameID else {
            throw CloudTranscriptionJobValidationError.historyIDMismatch
        }
        guard Self.isSafeBasename(identity.source.audioFileName) else {
            throw CloudTranscriptionJobValidationError.unsafeAudioFileName
        }
        guard identity.source.frameCount > 0,
              identity.source.dataByteCount
                == identity.source.frameCount
                    * UInt64(CanonicalPCM16WAV.bytesPerFrame),
              identity.source.physicalByteCount
                == CanonicalPCM16WAV.headerByteCount
                    + identity.source.dataByteCount,
              identity.source.sha256.count == 64 else {
            throw CloudTranscriptionJobValidationError.invalidSourceIdentity
        }
        guard identity.source.frameCount == plan.sourceFrameCount else {
            throw CloudTranscriptionJobValidationError.sourcePlanMismatch
        }
        guard identity.planID == plan.planID else {
            throw CloudTranscriptionJobValidationError.identityPlanMismatch
        }
        do {
            try plan.validate()
        } catch {
            throw CloudTranscriptionJobValidationError.invalidPlan
        }
        guard completedChunks.count <= plan.chunks.count,
              completedChunks.enumerated().allSatisfy({ offset, chunk in
                  chunk.index == offset
              }) else {
            throw CloudTranscriptionJobValidationError.invalidCompletedChunkPrefix
        }
        guard firstIncompleteChunkIndex == completedChunks.count else {
            throw CloudTranscriptionJobValidationError
                .firstIncompleteChunkIndexMismatch
        }
        if phase == .assembled,
           completedChunks.count != plan.chunks.count {
            throw CloudTranscriptionJobValidationError.assembledBeforeComplete
        }
    }

    private static func isSafeBasename(_ value: String) -> Bool {
        guard !value.isEmpty,
              value != ".",
              value != "..",
              !value.hasPrefix("/"),
              !value.contains("/"),
              !value.contains("\\") else {
            return false
        }
        return URL(fileURLWithPath: value).lastPathComponent == value
    }
}
