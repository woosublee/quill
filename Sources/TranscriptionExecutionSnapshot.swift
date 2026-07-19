import CryptoKit
import Foundation

enum CloudTranscriptionProviderIdentityError: Error, Equatable {
    case invalidURL
    case unsupportedScheme
    case missingHost
    case embeddedCredentials
    case queryOrFragment
    case invalidModel
    case invalidUploadCeiling
}

struct CloudTranscriptionExecutionSnapshot: Sendable {
    let baseURL: URL
    let providerID: String
    let apiKey: String
    let model: String
    let language: String?
    let responseFormat: String
    let encodedUploadCeilingBytes: UInt64

    init(
        baseURL: String,
        apiKey: String,
        model: String,
        language: String?,
        responseFormat: String? = nil,
        encodedUploadCeilingBytes: UInt64
    ) throws {
        let normalizedURL = try Self.normalizedBaseURL(from: baseURL)
        let normalizedModel = model.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedModel.isEmpty else {
            throw CloudTranscriptionProviderIdentityError.invalidModel
        }
        guard encodedUploadCeilingBytes > 0 else {
            throw CloudTranscriptionProviderIdentityError.invalidUploadCeiling
        }
        let normalizedLanguage = language?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let resolvedLanguage = normalizedLanguage?.isEmpty == false
            ? normalizedLanguage
            : nil
        let normalizedResponseFormat = responseFormat?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        self.baseURL = normalizedURL
        self.providerID = Self.providerIdentity(for: normalizedURL)
        self.apiKey = apiKey
        self.model = normalizedModel
        self.language = resolvedLanguage
        self.responseFormat = normalizedResponseFormat?.isEmpty == false
            ? normalizedResponseFormat!
            : Self.responseFormat(forModel: normalizedModel)
        self.encodedUploadCeilingBytes = encodedUploadCeilingBytes
    }

    private static func normalizedBaseURL(from value: String) throws -> URL {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed) else {
            throw CloudTranscriptionProviderIdentityError.invalidURL
        }
        guard let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw CloudTranscriptionProviderIdentityError.unsupportedScheme
        }
        guard components.user == nil, components.password == nil else {
            throw CloudTranscriptionProviderIdentityError.embeddedCredentials
        }
        guard components.query == nil, components.fragment == nil else {
            throw CloudTranscriptionProviderIdentityError.queryOrFragment
        }
        guard let host = components.host?.lowercased(), !host.isEmpty else {
            throw CloudTranscriptionProviderIdentityError.missingHost
        }

        components.scheme = scheme
        components.host = host
        if components.port == Self.defaultPort(for: scheme) {
            components.port = nil
        }
        if components.path == "/" {
            components.path = ""
        } else {
            components.path = components.path.replacingOccurrences(
                of: "/+$",
                with: "",
                options: .regularExpression
            )
        }
        guard let normalizedURL = components.url else {
            throw CloudTranscriptionProviderIdentityError.invalidURL
        }
        return normalizedURL
    }

    private static func defaultPort(for scheme: String) -> Int? {
        switch scheme {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }

    private static func providerIdentity(for baseURL: URL) -> String {
        SHA256.hash(data: Data(baseURL.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func responseFormat(forModel model: String) -> String {
        let verboseJSONModels: Set<String> = [
            "whisper-1",
            "whisper-large-v3",
            "whisper-large-v3-turbo"
        ]
        return verboseJSONModels.contains(model.lowercased())
            ? "verbose_json"
            : "json"
    }
}

struct LocalTranscriptionExecutionSnapshot: Equatable, Sendable {
    let model: TranscriptionModel
    let localWhisperPath: String?
    let useLegacyMlxWhisper: Bool
    let language: TranscriptionLanguage
}

struct TranscriptionCompletionSnapshot: Codable, Equatable, Sendable {
    let postProcessingEnabled: Bool
    let preserveExactWording: Bool
    let outputLanguage: String
    let pressEnterCommandEnabled: Bool

    var cloudJobPolicy: CloudTranscriptionCompletionPolicy {
        CloudTranscriptionCompletionPolicy(
            postProcessingEnabled: postProcessingEnabled,
            preserveExactWording: preserveExactWording,
            outputLanguage: outputLanguage,
            pressEnterCommandEnabled: pressEnterCommandEnabled
        )
    }
}

enum TranscriptionExecutionSnapshot: Sendable {
    case cloud(
        CloudTranscriptionExecutionSnapshot,
        TranscriptionCompletionSnapshot
    )
    case local(
        LocalTranscriptionExecutionSnapshot,
        TranscriptionCompletionSnapshot
    )

    var completion: TranscriptionCompletionSnapshot {
        switch self {
        case .cloud(_, let completion), .local(_, let completion):
            return completion
        }
    }
}
