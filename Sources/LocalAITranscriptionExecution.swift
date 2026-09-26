import Foundation

/// The selected Local AI package is missing, incomplete, or corrupt.
struct LocalAITranscriptionModelUnavailableFailure: Error, Equatable, Sendable {}

/// Everything a Local AI transcription needs, captured before async work so one
/// job always uses one model environment (like `NativeWhisperExecutionSnapshot`).
struct LocalAITranscriptionExecutionSnapshot: Sendable {
    static let backendLabel = "Local AI"
    static let chunkTimeoutSeconds: TimeInterval = 120

    let modelID: String
    let displayName: String
    let packageDigest: String
    let requestFormat: LocalASRRequestFormat
    let modelIsReady: @Sendable () -> Bool
    let prepareAudio:
        @Sendable (URL) async throws -> NativeWhisperExecutionSnapshot.PreparedAudio
    let transcribeChunk:
        @Sendable (_ chunkURL: URL, _ languageCode: String?, _ timeoutSeconds: TimeInterval) async throws -> String

    var providerID: String {
        CloudTranscriptionJobIdentity.localAIProviderID(packageDigest: packageDigest)
    }

    func resumeIdentity(language: String?) -> LocalAITranscriptionResumeIdentity {
        LocalAITranscriptionResumeIdentity(
            providerID: providerID,
            model: modelID,
            language: language,
            responseFormat: requestFormat.rawValue,
            ceilingBytes: (try? TranscriptionChunkSizing.rawWAV.encodedByteCount(
                frameCount: LocalTranscriptionChunkLimits.maximumFrameCount
            )) ?? 0,
            silenceSearchFrameCount: LocalTranscriptionChunkLimits.silenceSearchFrameCount
        )
    }
}
