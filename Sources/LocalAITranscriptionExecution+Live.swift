import CryptoKit
import Foundation

/// Binds a Local AI transcription snapshot to the installed model package and
/// the shared `llama-server`. Kept apart from the snapshot type so standalone
/// tests do not need the server manager.
extension LocalAITranscriptionExecutionSnapshot {
    static func packageDigest(for model: LocalAIModel) -> String {
        let joined = model.artifacts.map(\.checksumSHA256).joined(separator: "\n")
        return SHA256.hash(data: Data(joined.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func live(
        model: LocalAIModel,
        isReady: Bool,
        serverManager: LocalAIServerManager,
        audioPreparation: AudioImportConversionService = AudioImportConversionService(),
        client: LocalASRTranscriptionClient = LocalASRTranscriptionClient()
    ) -> LocalAITranscriptionExecutionSnapshot? {
        guard let format = model.transcriptionRequestFormat else { return nil }
        return LocalAITranscriptionExecutionSnapshot(
            modelID: model.id,
            displayName: model.displayName,
            packageDigest: packageDigest(for: model),
            requestFormat: format,
            modelIsReady: { isReady },
            prepareAudio: { sourceURL in
                let prepared = try await audioPreparation.prepareForNativeWhisper(sourceURL)
                return NativeWhisperExecutionSnapshot.PreparedAudio(
                    fileURL: prepared.fileURL,
                    cleanup: { prepared.cleanup() }
                )
            },
            transcribeChunk: { chunkURL, languageCode, timeout in
                do {
                    return try await serverManager.withBaseURL(for: model) { baseURL in
                        try await client.transcribe(
                            chunkURL: chunkURL,
                            baseURL: baseURL,
                            format: format,
                            languageCode: languageCode,
                            timeoutSeconds: timeout
                        )
                    }
                } catch let error as LocalAIServerManagerError {
                    switch error {
                    case .modelUnavailable, .modelCorrupt:
                        throw LocalAITranscriptionModelUnavailableFailure()
                    case .startFailed:
                        throw TranscriptionChunkRuntimeFailure(reason: "startFailed")
                    case .processExited:
                        throw TranscriptionChunkRuntimeFailure(reason: "processExited")
                    }
                }
            }
        )
    }
}
