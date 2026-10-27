import CryptoKit
import Foundation
import QuillProviderCore

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
            : CloudTranscriptionUpload.responseFormat(forModel: normalizedModel)
        self.encodedUploadCeilingBytes = encodedUploadCeilingBytes
    }

    static func normalizedBaseURL(from value: String) throws -> URL {
        do {
            return try CloudProviderURL.normalized(value)
        } catch let error as CloudProviderURLError {
            switch error {
            case .invalidURL: throw CloudTranscriptionProviderIdentityError.invalidURL
            case .unsupportedScheme: throw CloudTranscriptionProviderIdentityError.unsupportedScheme
            case .missingHost: throw CloudTranscriptionProviderIdentityError.missingHost
            case .embeddedCredentials: throw CloudTranscriptionProviderIdentityError.embeddedCredentials
            case .queryOrFragment: throw CloudTranscriptionProviderIdentityError.queryOrFragment
            }
        }
    }

    private static func providerIdentity(for baseURL: URL) -> String {
        SHA256.hash(data: Data(baseURL.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

struct LocalTranscriptionExecutionSnapshot: Sendable {
    let model: TranscriptionModel
    let localWhisperPath: String?
    let useLegacyMlxWhisper: Bool
    let language: TranscriptionLanguage
    let nativeWhisperExecution: NativeWhisperExecutionSnapshot?
    let localAIExecution: LocalAITranscriptionExecutionSnapshot?

    init(
        model: TranscriptionModel,
        localWhisperPath: String?,
        useLegacyMlxWhisper: Bool,
        language: TranscriptionLanguage,
        nativeWhisperExecution: NativeWhisperExecutionSnapshot? = nil,
        localAIExecution: LocalAITranscriptionExecutionSnapshot? = nil
    ) {
        self.model = model
        self.localWhisperPath = localWhisperPath
        self.useLegacyMlxWhisper = useLegacyMlxWhisper
        self.language = language
        self.nativeWhisperExecution = nativeWhisperExecution
        self.localAIExecution = localAIExecution
    }
}

struct TranscriptionCompletionSnapshot: Codable, Equatable, Sendable {
    let postProcessingEnabled: Bool
    let outputLanguage: String
    let pressEnterCommandEnabled: Bool

    var cloudJobPolicy: CloudTranscriptionCompletionPolicy {
        CloudTranscriptionCompletionPolicy(
            postProcessingEnabled: postProcessingEnabled,
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
