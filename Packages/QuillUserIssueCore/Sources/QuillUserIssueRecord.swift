import Foundation

public enum QuillUserIssueCode: String, Codable, CaseIterable, Sendable {
    case networkUnavailable = "network-unavailable"
    case networkConnectionLost = "network-connection-lost"
    case requestTimedOut = "request-timed-out"
    case rateLimited = "rate-limited"
    case authenticationFailed = "authentication-failed"
    case quotaExceeded = "quota-exceeded"
    case providerUnavailable = "provider-unavailable"
    case providerConfigurationInvalid = "provider-configuration-invalid"
    case audioFileTooLarge = "audio-file-too-large"
    case invalidProviderResponse = "invalid-provider-response"
    case audioUnreadable = "audio-unreadable"
    case audioPreparationFailed = "audio-preparation-failed"
    case localRuntimeMissing = "local-runtime-missing"
    case localModelMissing = "local-model-missing"
    case localDependencyMissing = "local-dependency-missing"
    case localTranscriptionFailed = "local-transcription-failed"
    /// Apple Speech has no on-device model for the language, and Quill won't
    /// send audio to Apple's servers.
    case appleSpeechOnDeviceUnavailable = "apple-speech-on-device-unavailable"
    case microphonePermissionDenied = "microphone-permission-denied"
    case speechRecognitionPermissionDenied = "speech-recognition-permission-denied"
    case screenRecordingPermissionDenied = "screen-recording-permission-denied"
    case recordingInputFailed = "recording-input-failed"
    case postProcessingFailed = "post-processing-failed"
    case postProcessingRateLimited = "post-processing-rate-limited"
    case postProcessingGuardFallback = "post-processing-guard-fallback"
    case postProcessingPayloadTooLarge = "post-processing-payload-too-large"
    case localAIModelUnavailable = "local-ai-model-unavailable"
    case localAIStartFailed = "local-ai-start-failed"
    case localAIProcessExited = "local-ai-process-exited"
    case contextUnavailable = "context-unavailable"
    case meetingSummaryUnavailable = "meeting-summary-unavailable"
    case meetingSummaryInvalidResponse = "meeting-summary-invalid-response"
    case meetingSummaryLanguageUnavailable = "meeting-summary-language-unavailable"
    case historyPersistenceUnavailable = "history-persistence-unavailable"
    case historyRecovered = "history-recovered"
    case unknown
    case legacy
}

public enum QuillUserIssueSeverity: String, Codable, Equatable, Sendable {
    case error
    case warning
}

/// A bounded, app-owned classification for a rejected meeting-summary result.
/// This value is deliberately safe to persist and display: it cannot represent
/// unbounded generated content, external service payloads, source text, request templates, or secrets.
public enum MeetingSummaryFailureSubtype: String, Codable, Equatable, Sendable {
    case emptyOutput
    case responseEnvelope
    case jsonSchema
    case outputTruncated
    case contextBudget
    case mergeBudget
    case sourceEvidenceMissing
    case sourceQuoteNotFound
    case overviewEvidenceCountInvalid
    case overviewEvidenceQuoteDuplicate
    case ownerNotGrounded
    case dueDateNotGrounded
    case languageMismatch
}

/// A finite, source-text-free explanation for a cleanup failure.
/// Unlike the underlying transport or model error, this is safe to persist
/// and display in history and warning-banner details.
public enum PostProcessingFailureReason: String, Codable, Equatable, Sendable {
    case requestTimedOut
    case contextBudgetExceeded
    case emptyOutput
    case invalidResponse
    case serviceRequestFailed
}

public enum ProviderDiagnosticCode {
    private static let allowedCodes: Set<String> = [
        "context_length_exceeded",
        "insufficient_quota",
        "internal_error",
        "invalid_request_error",
        "model_not_found",
        "overloaded_error",
        "rate_limit",
        "rate_limit_exceeded",
        "server_error",
        "service_unavailable",
        "temporarily_unavailable"
    ]

    public static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let code = value.lowercased()
        return allowedCodes.contains(code) ? code : nil
    }
}

public enum QuillUserIssueOperation: String, Codable, Equatable, Sendable {
    case postProcessing
    case commandTransform
}

public struct QuillUserIssueContext: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case httpStatus
        case providerHost
        case providerCode
        case modelID
        case localBackend
        case processExitCode
        case retryExhausted
        case meetingSummaryFailureSubtype
        case operation
        case postProcessingFailureReason
        case requestTimeoutSeconds
    }

    public let httpStatus: Int?
    public let providerHost: String?
    public let providerCode: String?
    public let modelID: String?
    public let localBackend: String?
    public let processExitCode: Int32?
    public let retryExhausted: Bool?
    public let meetingSummaryFailureSubtype: MeetingSummaryFailureSubtype?
    public let operation: QuillUserIssueOperation?
    public let postProcessingFailureReason: PostProcessingFailureReason?
    public let requestTimeoutSeconds: TimeInterval?

    public init(
        httpStatus: Int? = nil,
        providerHost: String? = nil,
        providerCode: String? = nil,
        modelID: String? = nil,
        localBackend: String? = nil,
        processExitCode: Int32? = nil,
        retryExhausted: Bool? = nil,
        meetingSummaryFailureSubtype: MeetingSummaryFailureSubtype? = nil,
        operation: QuillUserIssueOperation? = nil,
        postProcessingFailureReason: PostProcessingFailureReason? = nil,
        requestTimeoutSeconds: TimeInterval? = nil
    ) {
        self.httpStatus = httpStatus
        self.providerHost = providerHost
        self.providerCode = ProviderDiagnosticCode.normalized(providerCode)
        self.modelID = modelID
        self.localBackend = localBackend
        self.processExitCode = processExitCode
        self.retryExhausted = retryExhausted
        self.meetingSummaryFailureSubtype = meetingSummaryFailureSubtype
        self.operation = operation
        self.postProcessingFailureReason = postProcessingFailureReason
        self.requestTimeoutSeconds = requestTimeoutSeconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            httpStatus: try container.decodeIfPresent(Int.self, forKey: .httpStatus),
            providerHost: try container.decodeIfPresent(String.self, forKey: .providerHost),
            providerCode: try container.decodeIfPresent(String.self, forKey: .providerCode),
            modelID: try container.decodeIfPresent(String.self, forKey: .modelID),
            localBackend: try container.decodeIfPresent(String.self, forKey: .localBackend),
            processExitCode: try container.decodeIfPresent(Int32.self, forKey: .processExitCode),
            retryExhausted: try container.decodeIfPresent(Bool.self, forKey: .retryExhausted),
            meetingSummaryFailureSubtype: try? container.decodeIfPresent(
                MeetingSummaryFailureSubtype.self,
                forKey: .meetingSummaryFailureSubtype
            ),
            operation: try? container.decodeIfPresent(
                QuillUserIssueOperation.self,
                forKey: .operation
            ),
            postProcessingFailureReason: try? container.decodeIfPresent(
                PostProcessingFailureReason.self,
                forKey: .postProcessingFailureReason
            ),
            requestTimeoutSeconds: try? container.decodeIfPresent(
                TimeInterval.self,
                forKey: .requestTimeoutSeconds
            )
        )
    }
}

public struct QuillUserIssueRecord: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let code: QuillUserIssueCode
    public let severity: QuillUserIssueSeverity
    public let context: QuillUserIssueContext

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        code: QuillUserIssueCode,
        severity: QuillUserIssueSeverity? = nil,
        context: QuillUserIssueContext = QuillUserIssueContext()
    ) {
        self.schemaVersion = schemaVersion
        self.code = code
        self.severity = severity ?? code.defaultSeverity
        self.context = context
    }
}

public extension QuillUserIssueContext {
    /// The same context without `providerHost`, which can name a private
    /// server. Notes leave the device without it.
    var withoutProviderHost: QuillUserIssueContext {
        QuillUserIssueContext(
            httpStatus: httpStatus,
            providerHost: nil,
            providerCode: providerCode,
            modelID: modelID,
            localBackend: localBackend,
            processExitCode: processExitCode,
            retryExhausted: retryExhausted,
            meetingSummaryFailureSubtype: meetingSummaryFailureSubtype,
            operation: operation,
            postProcessingFailureReason: postProcessingFailureReason,
            requestTimeoutSeconds: requestTimeoutSeconds
        )
    }
}

public extension QuillUserIssueRecord {
    /// The same record without the provider host in its context.
    var withoutProviderHost: QuillUserIssueRecord {
        QuillUserIssueRecord(
            schemaVersion: schemaVersion,
            code: code,
            severity: severity,
            context: context.withoutProviderHost
        )
    }
}

public extension QuillUserIssueCode {
    var defaultSeverity: QuillUserIssueSeverity {
        switch self {
        case .postProcessingFailed, .postProcessingRateLimited,
             .postProcessingGuardFallback, .postProcessingPayloadTooLarge,
             .localAIModelUnavailable,
             .localAIStartFailed, .localAIProcessExited,
             .contextUnavailable, .meetingSummaryUnavailable,
             .meetingSummaryInvalidResponse, .historyPersistenceUnavailable,
             .historyRecovered:
            return .warning
        default:
            return .error
        }
    }
}
