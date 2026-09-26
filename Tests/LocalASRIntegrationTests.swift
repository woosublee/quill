import Foundation

/// Opt-in check against a real Gemma 4 E4B `llama-server` (make
/// test-local-asr-integration). Uses synthetic recordings the developer
/// generates locally; prints sizes and timings only, never transcript text.
@main
struct LocalASRIntegrationTests {
    static func main() async {
        let environment = ProcessInfo.processInfo.environment
        guard let fixtureDirectory = environment["QUILL_ASR_FIXTURE_DIR"],
              !fixtureDirectory.isEmpty else {
            print("[skip] QUILL_ASR_FIXTURE_DIR is not set.")
            return
        }
        guard let baseURLString = environment["QUILL_LOCAL_AI_INTEGRATION_BASE_URL"],
              let baseURL = URL(string: baseURLString) else {
            fputs("LocalASRIntegrationTests failed: server base URL missing\n", stderr)
            exit(1)
        }
        do {
            let fixtures = try FileManager.default
                .contentsOfDirectory(atPath: fixtureDirectory)
                .filter { $0.lowercased().hasSuffix(".wav") }
                .sorted()
            guard !fixtures.isEmpty else {
                print("[skip] No .wav fixtures in QUILL_ASR_FIXTURE_DIR.")
                return
            }
            for name in fixtures {
                try await check(
                    fileURL: URL(fileURLWithPath: fixtureDirectory)
                        .appendingPathComponent(name),
                    baseURL: baseURL
                )
            }
            print("LocalASRIntegrationTests passed")
        } catch {
            fputs("LocalASRIntegrationTests failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func check(fileURL: URL, baseURL: URL) async throws {
        let layout = try CanonicalPCM16WAV.validateFile(at: fileURL)
        let source = try CloudTranscriptionSourceIdentityBuilder.make(
            fileURL: fileURL,
            layout: layout
        )
        let plan = try CloudTranscriptionChunkPlanner().planLocal(
            fileURL: fileURL,
            source: source,
            wavLayout: layout
        )
        for chunk in plan.chunks {
            guard chunk.endFrame - chunk.startFrame
                <= LocalTranscriptionChunkLimits.maximumFrameCount else {
                throw IntegrationFailure("\(fileURL.lastPathComponent): chunk over 60 s")
            }
        }

        let modelID = ProcessInfo.processInfo.environment["QUILL_ASR_MODEL_ID"]
            ?? LocalAIModelCatalog.gemma4E4B.id
        guard let model = LocalAIModelCatalog.model(id: modelID),
              let format = model.transcriptionRequestFormat else {
            throw IntegrationFailure("\(modelID) is not a transcription model")
        }
        let client = LocalASRTranscriptionClient()
        let language = languageCode(for: fileURL)
        let core = CloudTranscriptionCore(
            configuration: CloudTranscriptionConfiguration(
                model: model.id,
                language: language,
                responseFormat: format.rawValue,
                encodedUploadCeilingBytes: plan.encodedUploadCeilingBytes,
                minimumAttemptTimeoutSeconds: 120,
                maximumAttemptTimeoutSeconds: 120
            ),
            materializer: CloudTranscriptionChunkMaterializer(
                temporaryRoot: FileManager.default.temporaryDirectory
                    .appendingPathComponent(
                        "quill-asr-integration-\(UUID().uuidString)",
                        isDirectory: true
                    ),
                copyBufferByteCount: 1_048_576
            ),
            retryPolicy: CloudTranscriptionRetryPolicy(
                maximumAttempts: 3,
                jitter: { _ in 0 }
            ),
            sleep: { try await Task.sleep(for: .seconds($0)) }
        )
        let identity = CloudTranscriptionJobIdentity(
            providerID: CloudTranscriptionJobIdentity.localAIProviderID(
                packageDigest: "integration"
            ),
            model: model.id,
            language: language,
            responseFormat: format.rawValue,
            source: source,
            planID: plan.planID
        )

        let started = Date()
        let text = try await core.transcribe(
            sourceURL: fileURL,
            sourceLayout: layout,
            sourceIdentity: source,
            plan: plan,
            identity: identity,
            sizing: .rawWAV,
            checkpointStore: InMemoryCloudTranscriptionCheckpointStore(),
            request: { chunkURL, timeout in
                try await client.transcribe(
                    chunkURL: chunkURL,
                    baseURL: baseURL,
                    format: format,
                    languageCode: language,
                    timeoutSeconds: timeout
                )
            },
            progress: { _ in }
        )
        let elapsed = Date().timeIntervalSince(started)
        let seconds = Double(layout.frameCount) / 16_000
        let characters = text.count
        print(String(
            format: "%@: %.0f s audio, %d chunks, %d chars, %.1f s",
            fileURL.lastPathComponent,
            seconds,
            plan.chunks.count,
            characters,
            elapsed
        ))

        // Floors that catch silently dropped audio; the Stage 3 spike produced
        // roughly 6 characters per second (ko) and 13 (en).
        let floor: Double? = switch language {
        case "ko": 3
        case "en": 8
        default: nil
        }
        if let floor, Double(characters) < floor * seconds {
            throw IntegrationFailure(
                "\(fileURL.lastPathComponent): output too short for its length"
            )
        }
    }

    private static func languageCode(for fileURL: URL) -> String? {
        let name = fileURL.deletingPathExtension().lastPathComponent.lowercased()
        if name.hasSuffix("-ko") { return "ko" }
        if name.hasSuffix("-en") { return "en" }
        return nil
    }
}

private struct IntegrationFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
