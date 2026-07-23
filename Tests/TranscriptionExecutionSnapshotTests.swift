import Foundation

@main
struct TranscriptionExecutionSnapshotTests {
    static func main() throws {
        try normalizesEquivalentProviderURLsToOneSecretFreeIdentity()
        try distinguishesProviderHostAndPath()
        try rejectsProviderURLCredentialsQueryAndFragment()
        try cloudSnapshotCapturesImmutableExecutionValues()
        try localSnapshotCapturesImmutableExecutionValues()
        try completionSnapshotConvertsToDurablePolicyWithoutSecrets()
        try completionPolicyDecodesLegacyPreserveExactWordingKey()
        try serviceFactoryStaysInTranscriptionServiceBoundary()
        print("TranscriptionExecutionSnapshotTests passed")
    }

    private static func normalizesEquivalentProviderURLsToOneSecretFreeIdentity() throws {
        let first = try CloudTranscriptionExecutionSnapshot(
            baseURL: " HTTPS://API.Example.com:443/openai/v1/ ",
            apiKey: "first-secret",
            model: " whisper-large-v3 ",
            language: " en ",
            encodedUploadCeilingBytes: 20_000_000
        )
        let second = try CloudTranscriptionExecutionSnapshot(
            baseURL: "https://api.example.com/openai/v1",
            apiKey: "second-secret",
            model: "whisper-large-v3",
            language: "en",
            encodedUploadCeilingBytes: 20_000_000
        )

        try expectEqual(
            first.baseURL.absoluteString,
            "https://api.example.com/openai/v1",
            "normalized provider URL"
        )
        try expectEqual(first.providerID, second.providerID, "equivalent provider ID")
        try expect(!first.providerID.contains(first.apiKey), "provider ID excludes API key")
        try expectEqual(first.providerID.count, 64, "provider ID SHA-256 length")
    }

    private static func distinguishesProviderHostAndPath() throws {
        let base = try makeCloudSnapshot(baseURL: "https://api.example.com/openai/v1")
        let otherHost = try makeCloudSnapshot(baseURL: "https://other.example.com/openai/v1")
        let otherPath = try makeCloudSnapshot(baseURL: "https://api.example.com/transcription/v1")

        try expect(base.providerID != otherHost.providerID, "different host identity")
        try expect(base.providerID != otherPath.providerID, "different path identity")
    }

    private static func rejectsProviderURLCredentialsQueryAndFragment() throws {
        for value in [
            "https://user:password@api.example.com/openai/v1",
            "https://api.example.com/openai/v1?api_key=secret",
            "https://api.example.com/openai/v1#secret"
        ] {
            do {
                _ = try makeCloudSnapshot(baseURL: value)
                throw TestFailure("sensitive provider URL must be rejected: \(value)")
            } catch is CloudTranscriptionProviderIdentityError {
                // expected
            }
        }
    }

    private static func cloudSnapshotCapturesImmutableExecutionValues() throws {
        var baseURL = "https://api.example.com/openai/v1/"
        var apiKey = "original-key"
        var model = "whisper-large-v3"
        var language: String? = "ko"
        var ceiling: UInt64 = 19_000_000

        let snapshot = try CloudTranscriptionExecutionSnapshot(
            baseURL: baseURL,
            apiKey: apiKey,
            model: model,
            language: language,
            encodedUploadCeilingBytes: ceiling
        )
        baseURL = "https://changed.example.com/v1"
        apiKey = "changed-key"
        model = "changed-model"
        language = "en"
        ceiling = 1

        try expectEqual(snapshot.baseURL.absoluteString, "https://api.example.com/openai/v1", "cloud base URL snapshot")
        try expectEqual(snapshot.apiKey, "original-key", "cloud API key snapshot")
        try expectEqual(snapshot.model, "whisper-large-v3", "cloud model snapshot")
        try expectEqual(snapshot.language, "ko", "cloud language snapshot")
        try expectEqual(snapshot.responseFormat, "verbose_json", "cloud response format snapshot")
        try expectEqual(snapshot.encodedUploadCeilingBytes, 19_000_000, "cloud ceiling snapshot")
        try expect(baseURL != snapshot.baseURL.absoluteString, "later base URL mutation ignored")
        try expect(apiKey != snapshot.apiKey, "later API key mutation ignored")
        try expect(model != snapshot.model, "later model mutation ignored")
        try expect(language != snapshot.language, "later language mutation ignored")
        try expect(ceiling != snapshot.encodedUploadCeilingBytes, "later ceiling mutation ignored")
    }

    private static func localSnapshotCapturesImmutableExecutionValues() throws {
        var model = TranscriptionModel.find(id: "mlx-community/whisper-large-v3-turbo")
        var path: String? = "/tmp/original-mlx-whisper"
        var useLegacy = true
        var language = TranscriptionLanguage.find(code: "ja")

        let snapshot = LocalTranscriptionExecutionSnapshot(
            model: model,
            localWhisperPath: path,
            useLegacyMlxWhisper: useLegacy,
            language: language
        )
        model = .default
        path = "/tmp/changed"
        useLegacy = false
        language = .auto

        try expectEqual(snapshot.model.id, "mlx-community/whisper-large-v3-turbo", "local model snapshot")
        try expectEqual(snapshot.localWhisperPath, "/tmp/original-mlx-whisper", "local path snapshot")
        try expectEqual(snapshot.useLegacyMlxWhisper, true, "local engine snapshot")
        try expectEqual(snapshot.language.code, "ja", "local language snapshot")
        try expect(model != snapshot.model, "later local model mutation ignored")
        try expect(path != snapshot.localWhisperPath, "later local path mutation ignored")
        try expect(useLegacy != snapshot.useLegacyMlxWhisper, "later local engine mutation ignored")
        try expect(language != snapshot.language, "later local language mutation ignored")
    }

    private static func completionSnapshotConvertsToDurablePolicyWithoutSecrets() throws {
        let snapshot = TranscriptionCompletionSnapshot(
            postProcessingEnabled: true,
            outputLanguage: "ko",
            pressEnterCommandEnabled: false
        )
        let policy = snapshot.cloudJobPolicy
        let data = try JSONEncoder().encode(snapshot)
        let json = String(decoding: data, as: UTF8.self)

        try expectEqual(
            policy,
            CloudTranscriptionCompletionPolicy(
                postProcessingEnabled: true,
                outputLanguage: "ko",
                pressEnterCommandEnabled: false
            ),
            "durable completion policy"
        )
        for forbidden in ["apiKey", "api_key", "authorization", "oauth"] {
            try expect(!json.lowercased().contains(forbidden.lowercased()), "completion snapshot excludes \(forbidden)")
        }
    }

    private static func completionPolicyDecodesLegacyPreserveExactWordingKey() throws {
        let legacyJSON = Data(
            """
            {
              "postProcessingEnabled": true,
              "preserveExactWording": true,
              "outputLanguage": "ko",
              "pressEnterCommandEnabled": false
            }
            """.utf8
        )

        let policy = try JSONDecoder().decode(
            CloudTranscriptionCompletionPolicy.self,
            from: legacyJSON
        )

        try expectEqual(policy.postProcessingEnabled, true, "legacy post-processing state")
        try expectEqual(policy.outputLanguage, "ko", "legacy output language")
        try expectEqual(policy.pressEnterCommandEnabled, false, "legacy press-enter state")
    }

    private static func serviceFactoryStaysInTranscriptionServiceBoundary() throws {
        let snapshotSource = try String(
            contentsOfFile: "Sources/TranscriptionExecutionSnapshot.swift",
            encoding: .utf8
        )
        let serviceSource = try String(
            contentsOfFile: "Sources/TranscriptionService.swift",
            encoding: .utf8
        )

        try expect(
            !snapshotSource.contains("TranscriptionService("),
            "snapshot model stays independent from service implementation"
        )
        try expect(
            serviceSource.contains("extension TranscriptionExecutionSnapshot"),
            "service factory lives beside TranscriptionService"
        )
    }

    private static func makeCloudSnapshot(
        baseURL: String
    ) throws -> CloudTranscriptionExecutionSnapshot {
        try CloudTranscriptionExecutionSnapshot(
            baseURL: baseURL,
            apiKey: "secret",
            model: "whisper-large-v3",
            language: "en",
            encodedUploadCeilingBytes: 20_000_000
        )
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ label: String
    ) throws {
        guard condition() else { throw TestFailure(label) }
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
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
