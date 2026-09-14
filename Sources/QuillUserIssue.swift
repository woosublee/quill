import Foundation

enum QuillUserIssueCode: String, Codable, CaseIterable, Sendable {
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

enum QuillUserIssueSeverity: String, Codable, Equatable, Sendable {
    case error
    case warning
}

/// A bounded, app-owned classification for a rejected meeting-summary result.
/// This value is deliberately safe to persist and display: it cannot represent
/// unbounded generated content, external service payloads, source text, request templates, or secrets.
enum MeetingSummaryFailureSubtype: String, Codable, Equatable, Sendable {
    case emptyOutput
    case responseEnvelope
    case jsonSchema
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
enum PostProcessingFailureReason: String, Codable, Equatable, Sendable {
    case requestTimedOut
    case contextBudgetExceeded
    case emptyOutput
    case invalidResponse
    case serviceRequestFailed
}

enum ProviderDiagnosticCode {
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

    static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let code = value.lowercased()
        return allowedCodes.contains(code) ? code : nil
    }
}

enum QuillUserIssueOperation: String, Codable, Equatable, Sendable {
    case postProcessing
    case commandTransform
}

struct QuillUserIssueContext: Codable, Equatable, Sendable {
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

    let httpStatus: Int?
    let providerHost: String?
    let providerCode: String?
    let modelID: String?
    let localBackend: String?
    let processExitCode: Int32?
    let retryExhausted: Bool?
    let meetingSummaryFailureSubtype: MeetingSummaryFailureSubtype?
    let operation: QuillUserIssueOperation?
    let postProcessingFailureReason: PostProcessingFailureReason?
    let requestTimeoutSeconds: TimeInterval?

    init(
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

    init(from decoder: Decoder) throws {
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

enum QuillUserRecoveryAction: Equatable, Sendable {
    case retryTranscription
    case openModelsSettings
    case openProviderSettings
    case openMicrophoneSettings
    case openSpeechRecognitionSettings
    case openScreenRecordingSettings
    case none
}

struct QuillUserIssueDetailsRow: Equatable, Sendable {
    let label: String
    let value: String
}

struct QuillUserIssuePresentation: Equatable, Sendable {
    let title: String
    let body: String
    let suggestion: String
    let compactMessage: String
    let detailsRows: [QuillUserIssueDetailsRow]
    let recoveryAction: QuillUserRecoveryAction
    let severity: QuillUserIssueSeverity
}

enum MeetingSummaryIssueAction: Equatable {
    case retrySummary
    case recovery(QuillUserRecoveryAction)

    static func resolve(
        _ presentation: QuillUserIssuePresentation
    ) -> MeetingSummaryIssueAction {
        switch presentation.recoveryAction {
        case .none, .retryTranscription:
            return .retrySummary
        default:
            return .recovery(presentation.recoveryAction)
        }
    }
}

enum QuillUserIssuePersistenceError: Error, Equatable {
    case invalidPrefix
    case unsupportedSchemaVersion(Int)
    case invalidEncoding
    case invalidPayload
}

struct QuillUserIssueRecord: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let persistedStatusPrefix = "user-issue:v1:"

    let schemaVersion: Int
    let code: QuillUserIssueCode
    let severity: QuillUserIssueSeverity
    let context: QuillUserIssueContext

    init(
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

    var persistedStatus: String {
        guard schemaVersion == Self.currentSchemaVersion else {
            return Self.encodeUnchecked(QuillUserIssueRecord(code: .unknown))
        }
        return Self.encodeUnchecked(self)
    }

    var recoveryAction: QuillUserRecoveryAction {
        if context.operation == .postProcessing,
           context.postProcessingFailureReason == .contextBudgetExceeded {
            return .none
        }
        switch code {
        case .authenticationFailed, .quotaExceeded,
             .providerConfigurationInvalid:
            return .openProviderSettings
        case .localRuntimeMissing, .localModelMissing,
             .localDependencyMissing, .localAIModelUnavailable,
             .meetingSummaryLanguageUnavailable:
            return .openModelsSettings
        case .microphonePermissionDenied:
            return .openMicrophoneSettings
        case .speechRecognitionPermissionDenied:
            return .openSpeechRecognitionSettings
        case .screenRecordingPermissionDenied:
            return .openScreenRecordingSettings
        case .postProcessingGuardFallback, .postProcessingPayloadTooLarge,
             .contextUnavailable, .meetingSummaryUnavailable,
             .meetingSummaryInvalidResponse, .historyPersistenceUnavailable,
             .historyRecovered:
            return .none
        case .networkUnavailable, .networkConnectionLost,
             .requestTimedOut, .rateLimited,
             .providerUnavailable, .audioFileTooLarge,
             .invalidProviderResponse, .audioUnreadable,
             .audioPreparationFailed, .localTranscriptionFailed,
             .localAIStartFailed, .localAIProcessExited,
             .recordingInputFailed, .postProcessingFailed,
             .postProcessingRateLimited, .unknown, .legacy:
            return .retryTranscription
        }
    }

    func presentation(
        language: String = preferredLocalizedStringLanguage(),
        bundle: Bundle = .main
    ) -> QuillUserIssuePresentation {
        let copy = code.copy(for: context)
        let title = localizedCatalogString(
            copy.titleKey,
            language: language,
            bundle: bundle
        )
        return QuillUserIssuePresentation(
            title: title,
            body: localizedCatalogString(
                copy.bodyKey,
                language: language,
                bundle: bundle
            ),
            suggestion: localizedCatalogString(
                copy.suggestionKey,
                language: language,
                bundle: bundle
            ),
            compactMessage: title,
            detailsRows: context.detailsRows(
                for: code,
                language: language,
                bundle: bundle
            ),
            recoveryAction: recoveryAction,
            severity: severity
        )
    }

    func encodedStatus() throws -> String {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw QuillUserIssuePersistenceError
                .unsupportedSchemaVersion(schemaVersion)
        }
        return Self.encodeUnchecked(self)
    }

    private static func encodeUnchecked(_ record: Self) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try! encoder.encode(record)
        return Self.persistedStatusPrefix + data.base64URLEncodedString()
    }

    static func decodePersistedStatus(_ status: String) throws -> Self {
        guard status.hasPrefix("user-issue:") else {
            throw QuillUserIssuePersistenceError.invalidPrefix
        }
        let components = status.split(
            separator: ":",
            maxSplits: 2,
            omittingEmptySubsequences: false
        )
        guard components.count == 3,
              components[0] == "user-issue",
              components[1].hasPrefix("v"),
              let version = Int(components[1].dropFirst()) else {
            throw QuillUserIssuePersistenceError.invalidPrefix
        }
        guard version == Self.currentSchemaVersion else {
            throw QuillUserIssuePersistenceError
                .unsupportedSchemaVersion(version)
        }
        guard let data = Data(base64URLString: String(components[2])) else {
            throw QuillUserIssuePersistenceError.invalidEncoding
        }
        let record: Self
        do {
            record = try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw QuillUserIssuePersistenceError.invalidPayload
        }
        guard record.schemaVersion == Self.currentSchemaVersion else {
            throw QuillUserIssuePersistenceError
                .unsupportedSchemaVersion(record.schemaVersion)
        }
        return record
    }
}

struct QuillUserIssueError: Error, Sendable {
    static let diagnosticCharacterLimit = 2_048

    let record: QuillUserIssueRecord
    let privateDiagnostic: String

    var persistedStatus: String { record.persistedStatus }

    init(record: QuillUserIssueRecord, privateDiagnostic: String = "") {
        self.record = record
        self.privateDiagnostic = String(
            privateDiagnostic.suffix(Self.diagnosticCharacterLimit)
        )
    }

    static func historyPersistenceUnavailable() -> Self {
        Self(record: QuillUserIssueRecord(code: .historyPersistenceUnavailable))
    }

    static func meetingSummaryLanguageUnavailable() -> Self {
        Self(record: QuillUserIssueRecord(code: .meetingSummaryLanguageUnavailable))
    }

    static func missingProviderAPIKey(
        providerHost: String?,
        modelID: String
    ) -> Self {
        Self(
            record: QuillUserIssueRecord(
                code: .providerConfigurationInvalid,
                context: QuillUserIssueContext(
                    providerHost: providerHost,
                    modelID: modelID
                )
            ),
            privateDiagnostic: "Provider API key is missing"
        )
    }

    static func cloudHTTP(
        status: Int,
        providerCode: String? = nil,
        providerType: String? = nil,
        providerHost: String?,
        modelID: String,
        retryExhausted: Bool? = nil
    ) -> Self {
        let normalizedCode = providerCode?.lowercased()
        let normalizedType = providerType?.lowercased()
        let code: QuillUserIssueCode
        if normalizedCode == "insufficient_quota"
            || normalizedType == "insufficient_quota" {
            code = .quotaExceeded
        } else {
            switch status {
            case 400, 404, 415, 422:
                code = .providerConfigurationInvalid
            case 401, 403:
                code = .authenticationFailed
            case 408:
                code = .requestTimedOut
            case 413:
                code = .audioFileTooLarge
            case 429:
                code = .rateLimited
            case 500..<600:
                code = .providerUnavailable
            default:
                code = .invalidProviderResponse
            }
        }
        return Self(
            record: QuillUserIssueRecord(
                code: code,
                context: QuillUserIssueContext(
                    httpStatus: status > 0 ? status : nil,
                    providerHost: providerHost,
                    modelID: modelID,
                    retryExhausted: retryExhausted
                )
            ),
            privateDiagnostic: [
                "HTTP \(status)",
                providerCode.map { "code=\($0)" },
                providerType.map { "type=\($0)" }
            ].compactMap { $0 }.joined(separator: " ")
        )
    }

    static func cloudTransport(
        _ error: Error,
        timedOut: Bool = false,
        providerHost: String?,
        modelID: String
    ) -> Self {
        let code: QuillUserIssueCode
        if timedOut {
            code = .requestTimedOut
        } else if let urlError = error as? URLError {
            switch urlError.code {
            case .networkConnectionLost:
                code = .networkConnectionLost
            case .notConnectedToInternet, .cannotConnectToHost,
                 .cannotFindHost, .dnsLookupFailed:
                code = .networkUnavailable
            case .timedOut:
                code = .requestTimedOut
            default:
                code = .providerUnavailable
            }
        } else {
            code = .providerUnavailable
        }
        let nsError = error as NSError
        return Self(
            record: QuillUserIssueRecord(
                code: code,
                context: QuillUserIssueContext(
                    providerHost: providerHost,
                    modelID: modelID
                )
            ),
            privateDiagnostic: "\(nsError.domain) \(nsError.code)"
        )
    }

    static func local(
        code: QuillUserIssueCode,
        backend: String,
        modelID: String? = nil,
        processExitCode: Int32? = nil,
        diagnostic: String = ""
    ) -> Self {
        Self(
            record: QuillUserIssueRecord(
                code: code,
                context: QuillUserIssueContext(
                    modelID: modelID,
                    localBackend: backend,
                    processExitCode: processExitCode
                )
            ),
            privateDiagnostic: diagnostic
        )
    }

    static func local(
        code: QuillUserIssueCode,
        backend: String,
        modelID: String? = nil,
        processExitCode: Int32? = nil,
        diagnosticCategory: String,
        diagnosticExcerpt: String
    ) -> Self {
        let category = "[\(diagnosticCategory)]"
        let maximumExcerptLength = max(0, diagnosticCharacterLimit - category.count - 1)
        let excerpt = String(diagnosticExcerpt.suffix(maximumExcerptLength))
        let diagnostic = excerpt.isEmpty ? category : "\(category) \(excerpt)"
        return local(
            code: code,
            backend: backend,
            modelID: modelID,
            processExitCode: processExitCode,
            diagnostic: diagnostic
        )
    }
}

private extension QuillUserIssueCode {
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

    func copy(
        for context: QuillUserIssueContext
    ) -> QuillUserIssueCopy {
        switch self {
        case .networkUnavailable:
            return QuillUserIssueCopy(
                titleKey: "No network connection",
                bodyKey: "Quill could not reach the transcription service because this Mac appears to be offline.",
                suggestionKey: "Check your internet connection, then try again."
            )
        case .networkConnectionLost:
            return QuillUserIssueCopy(
                titleKey: "Connection lost",
                bodyKey: "The connection to the transcription service was interrupted before the request completed.",
                suggestionKey: "Try again or switch to another network."
            )
        case .requestTimedOut:
            switch context.operation {
            case .postProcessing:
                return QuillUserIssueCopy(
                    titleKey: "Transcript cleanup timed out",
                    bodyKey: "Quill kept the original transcript because cleanup did not finish in time.",
                    suggestionKey: "Use the original transcript or try cleanup again later."
                )
            case .commandTransform:
                return QuillUserIssueCopy(
                    titleKey: "Text edit timed out",
                    bodyKey: "Quill kept the selected text because the edit did not finish in time.",
                    suggestionKey: "Use the selected text or try the edit again later."
                )
            case nil:
                return QuillUserIssueCopy(
                    titleKey: "Transcription timed out",
                    bodyKey: "The transcription service did not respond in time.",
                    suggestionKey: "Try again. If this keeps happening, check the provider status or choose another configured model."
                )
            }
        case .rateLimited:
            return QuillUserIssueCopy(
                titleKey: "Transcription is temporarily limited",
                bodyKey: "The provider is receiving too many requests right now.",
                suggestionKey: "Wait a moment, then try again."
            )
        case .authenticationFailed:
            return QuillUserIssueCopy(
                titleKey: "Provider sign-in needs attention",
                bodyKey: "Quill could not authenticate with the selected provider.",
                suggestionKey: "Check the API key or account connection in Models settings."
            )
        case .quotaExceeded:
            return QuillUserIssueCopy(
                titleKey: "Provider quota reached",
                bodyKey: "The selected provider account has no remaining quota or billing access.",
                suggestionKey: "Review the provider account, then try again."
            )
        case .providerUnavailable:
            return QuillUserIssueCopy(
                titleKey: "Transcription service unavailable",
                bodyKey: "The selected provider is temporarily unavailable.",
                suggestionKey: "Try again later or choose another configured provider."
            )
        case .providerConfigurationInvalid:
            return QuillUserIssueCopy(
                titleKey: "Provider setup needs attention",
                bodyKey: "The selected provider or model is not configured correctly.",
                suggestionKey: "Review the provider and model in Models settings."
            )
        case .audioFileTooLarge:
            return QuillUserIssueCopy(
                titleKey: "Recording is too large",
                bodyKey: "The provider cannot accept this recording in one request.",
                suggestionKey: "Choose a supported provider or shorten the recording, then try again."
            )
        case .invalidProviderResponse:
            return QuillUserIssueCopy(
                titleKey: "Transcription response could not be read",
                bodyKey: "The provider returned a response Quill could not use.",
                suggestionKey: "Try again. If it continues, check the provider configuration."
            )
        case .audioUnreadable:
            return QuillUserIssueCopy(
                titleKey: "Audio could not be read",
                bodyKey: "Quill cannot access the saved recording.",
                suggestionKey: "Make sure the recording still exists and is readable, then try again."
            )
        case .audioPreparationFailed:
            return QuillUserIssueCopy(
                titleKey: "Audio could not be prepared",
                bodyKey: "Quill could not convert the recording for transcription.",
                suggestionKey: "Try again. If it continues, use a different audio file."
            )
        case .localRuntimeMissing:
            return QuillUserIssueCopy(
                titleKey: "Local transcription is not ready",
                bodyKey: "The local transcription helper is unavailable.",
                suggestionKey: "Open Models settings and repair the local transcription setup."
            )
        case .localModelMissing:
            return QuillUserIssueCopy(
                titleKey: "Local model is missing",
                bodyKey: "The selected local transcription model is not installed.",
                suggestionKey: "Open Models settings to install or select a model."
            )
        case .localDependencyMissing:
            return QuillUserIssueCopy(
                titleKey: "Local transcription dependency is missing",
                bodyKey: "A required local transcription component is unavailable.",
                suggestionKey: "Open Models settings and repair the local transcription setup."
            )
        case .localTranscriptionFailed:
            return QuillUserIssueCopy(
                titleKey: "Local transcription failed",
                bodyKey: "The local transcription process could not complete.",
                suggestionKey: "Try again or choose another configured transcription model."
            )
        case .localAIModelUnavailable:
            return QuillUserIssueCopy(
                titleKey: "Local AI model needs attention",
                bodyKey: "Quill kept the original transcript because the selected on-device model is unavailable or incomplete.",
                suggestionKey: "Open Models settings to install the model again or select another model."
            )
        case .localAIStartFailed:
            return QuillUserIssueCopy(
                titleKey: "Local AI could not start",
                bodyKey: "Quill kept the original transcript because the on-device processing runtime did not become ready.",
                suggestionKey: "Try again. If this continues, restart Quill or reinstall the app."
            )
        case .localAIProcessExited:
            return QuillUserIssueCopy(
                titleKey: "Local AI stopped unexpectedly",
                bodyKey: "Quill kept the original transcript because the on-device processing runtime stopped during the request.",
                suggestionKey: "Try the cleanup again. If this continues, choose another model."
            )
        case .microphonePermissionDenied:
            return QuillUserIssueCopy(
                titleKey: "Microphone access is required",
                bodyKey: "Quill cannot record microphone audio without permission.",
                suggestionKey: "Allow microphone access in System Settings, then try again."
            )
        case .speechRecognitionPermissionDenied:
            return QuillUserIssueCopy(
                titleKey: "Speech Recognition access is required",
                bodyKey: "Apple Speech transcription cannot run without permission.",
                suggestionKey: "Allow Speech Recognition access in System Settings, then try again."
            )
        case .screenRecordingPermissionDenied:
            return QuillUserIssueCopy(
                titleKey: "Screen Recording access is required",
                bodyKey: "Quill cannot capture system audio or visual context without permission.",
                suggestionKey: "Allow Screen Recording access in System Settings, then try again."
            )
        case .recordingInputFailed:
            return QuillUserIssueCopy(
                titleKey: "Recording input failed",
                bodyKey: "Quill could not continue receiving audio.",
                suggestionKey: "Check the selected input and permissions, then try again."
            )
        case .postProcessingFailed:
            guard context.operation == .postProcessing else {
                return QuillUserIssueCopy(
                    titleKey: "Transcript cleanup was skipped",
                    bodyKey: "Quill kept the original transcript because cleanup could not complete.",
                    suggestionKey: "You can use the transcript as-is or try cleanup again later."
                )
            }
            switch context.postProcessingFailureReason {
            case .contextBudgetExceeded:
                return QuillUserIssueCopy(
                    titleKey: "Transcript cleanup instructions are too large",
                    bodyKey: "Quill kept the original transcript because the cleanup instructions or context could not fit safely in the selected model.",
                    suggestionKey: "Review the cleanup prompt, context, and vocabulary before trying again."
                )
            case .emptyOutput:
                return QuillUserIssueCopy(
                    titleKey: "Transcript cleanup returned no text",
                    bodyKey: "Quill kept the original transcript because the model returned no cleanup text.",
                    suggestionKey: "Use the original transcript or try cleanup again later."
                )
            case .invalidResponse:
                return QuillUserIssueCopy(
                    titleKey: "Transcript cleanup response could not be read",
                    bodyKey: "Quill kept the original transcript because the model response was not usable.",
                    suggestionKey: "Use the original transcript or try cleanup again later."
                )
            case .serviceRequestFailed:
                return QuillUserIssueCopy(
                    titleKey: "Transcript cleanup request failed",
                    bodyKey: "Quill kept the original transcript because the cleanup service rejected or could not complete the request.",
                    suggestionKey: "Use the original transcript or try cleanup again later."
                )
            case .requestTimedOut, nil:
                return QuillUserIssueCopy(
                    titleKey: "Transcript cleanup was skipped",
                    bodyKey: "Quill kept the original transcript because cleanup could not complete.",
                    suggestionKey: "You can use the transcript as-is or try cleanup again later."
                )
            }
        case .postProcessingRateLimited:
            return QuillUserIssueCopy(
                titleKey: "Transcript cleanup is temporarily limited",
                bodyKey: "Quill kept the original transcript because the model is rate-limited.",
                suggestionKey: "Wait a moment and try cleanup again."
            )
        case .postProcessingGuardFallback:
            return QuillUserIssueCopy(
                titleKey: "Original transcript kept",
                bodyKey: "Post-processing was not applied; the original transcript was kept.",
                suggestionKey: "Review the original transcript before using it."
            )
        case .postProcessingPayloadTooLarge:
            return QuillUserIssueCopy(
                titleKey: "Transcript too long to clean up",
                bodyKey: "Quill kept the original transcript because it was too large for the selected provider to clean up in one request.",
                suggestionKey: "Use the original transcript, or choose a different provider or model for cleanup."
            )
        case .contextUnavailable:
            return QuillUserIssueCopy(
                titleKey: "Context wasn't available",
                bodyKey: "Continued with text-only post-processing.",
                suggestionKey: "No action needed. Context capture will be attempted again next time."
            )
        case .meetingSummaryUnavailable:
            return QuillUserIssueCopy(
                titleKey: "Summary service unavailable",
                bodyKey: "The selected provider could not create a meeting summary right now.",
                suggestionKey: "Try Regenerate again later, or choose another configured model in Meeting Summary settings."
            )
        case .meetingSummaryInvalidResponse:
            return QuillUserIssueCopy(
                titleKey: "Summary response could not be read",
                bodyKey: "The provider returned a response Quill could not use for the summary.",
                suggestionKey: "Try Regenerate again. If it continues, check the provider configuration."
            )
        case .meetingSummaryLanguageUnavailable:
            return QuillUserIssueCopy(
                titleKey: "Summary language could not be determined",
                bodyKey: "Quill could not determine the spoken language for this meeting summary.",
                suggestionKey: "Choose an output language in Models settings, then try again."
            )
        case .historyPersistenceUnavailable:
            return QuillUserIssueCopy(
                titleKey: "History isn't being saved",
                bodyKey: "Quill cannot save history for this session.",
                suggestionKey: "Keep Quill open while you work, then restart it after checking available disk space and permissions."
            )
        case .historyRecovered:
            return QuillUserIssueCopy(
                titleKey: "History was recovered",
                bodyKey: "Quill couldn't open earlier history. A recovery backup was retained, and new notes will keep saving.",
                suggestionKey: "No action is needed. Your new notes and history are being saved."
            )
        case .unknown:
            return QuillUserIssueCopy(
                titleKey: "Something went wrong",
                bodyKey: "Quill could not complete this transcription.",
                suggestionKey: "Try again. If it continues, review your transcription settings."
            )
        case .legacy:
            return QuillUserIssueCopy(
                titleKey: "Transcription failed",
                bodyKey: "This older history item does not include a safe error category.",
                suggestionKey: "Try the transcription again to get updated guidance."
            )
        }
    }
}

private struct QuillUserIssueCopy {
    let titleKey: String
    let bodyKey: String
    let suggestionKey: String
}

private extension MeetingSummaryFailureSubtype {
    func localizedDetailsValue(language: String, bundle: Bundle) -> String {
        let key: String
        switch self {
        case .emptyOutput:
            key = "Empty output"
        case .responseEnvelope:
            key = "Response envelope"
        case .jsonSchema:
            key = "Summary format"
        case .contextBudget:
            key = "Context budget"
        case .mergeBudget:
            key = "Merge budget"
        case .sourceEvidenceMissing:
            key = "Source evidence missing"
        case .sourceQuoteNotFound:
            key = "Source quote not found"
        case .overviewEvidenceCountInvalid:
            key = "Overview evidence"
        case .overviewEvidenceQuoteDuplicate:
            key = "Duplicate overview evidence"
        case .ownerNotGrounded:
            key = "Owner is not grounded"
        case .dueDateNotGrounded:
            key = "Due date is not grounded"
        case .languageMismatch:
            key = "Output language mismatch"
        }
        return localizedCatalogString(key, language: language, bundle: bundle)
    }
}

private extension PostProcessingFailureReason {
    func localizedDetailsValue(language: String, bundle: Bundle) -> String {
        let key: String
        switch self {
        case .requestTimedOut:
            key = "Request timed out"
        case .contextBudgetExceeded:
            key = "Cleanup instructions or context are too large"
        case .emptyOutput:
            key = "Model returned no cleanup text"
        case .invalidResponse:
            key = "Model response could not be read"
        case .serviceRequestFailed:
            key = "Cleanup service request failed"
        }
        return localizedCatalogString(key, language: language, bundle: bundle)
    }
}

private extension QuillUserIssueContext {
    func detailsRows(
        for issueCode: QuillUserIssueCode,
        language: String,
        bundle: Bundle
    ) -> [QuillUserIssueDetailsRow] {
        var rows: [QuillUserIssueDetailsRow] = []
        if let httpStatus {
            rows.append(
                QuillUserIssueDetailsRow(
                    label: localizedCatalogString("HTTP status", language: language, bundle: bundle),
                    value: String(httpStatus)
                )
            )
        }
        if let providerHost, !providerHost.isEmpty {
            rows.append(
                QuillUserIssueDetailsRow(
                    label: localizedCatalogString("Provider", language: language, bundle: bundle),
                    value: providerHost
                )
            )
        }
        if let providerCode, !providerCode.isEmpty {
            rows.append(
                QuillUserIssueDetailsRow(
                    label: localizedCatalogString("Provider code", language: language, bundle: bundle),
                    value: providerCode
                )
            )
        }
        if let modelID, !modelID.isEmpty {
            rows.append(
                QuillUserIssueDetailsRow(
                    label: localizedCatalogString("Model", language: language, bundle: bundle),
                    value: modelID
                )
            )
        }
        if operation == .postProcessing {
            rows.append(
                QuillUserIssueDetailsRow(
                    label: localizedCatalogString("Operation", language: language, bundle: bundle),
                    value: localizedCatalogString("Transcript cleanup", language: language, bundle: bundle)
                )
            )
            if let postProcessingFailureReason {
                rows.append(
                    QuillUserIssueDetailsRow(
                        label: localizedCatalogString("Failure reason", language: language, bundle: bundle),
                        value: postProcessingFailureReason.localizedDetailsValue(
                            language: language,
                            bundle: bundle
                        )
                    )
                )
            }
            if let requestTimeoutSeconds,
               requestTimeoutSeconds.isFinite,
               requestTimeoutSeconds > 0 {
                let timeoutValue = localizedCatalogFormat(
                    "%g seconds",
                    requestTimeoutSeconds,
                    language: language,
                    bundle: bundle
                )
                rows.append(
                    QuillUserIssueDetailsRow(
                        label: localizedCatalogString("Request timeout", language: language, bundle: bundle),
                        value: timeoutValue
                    )
                )
            }
        }
        if issueCode == .meetingSummaryInvalidResponse,
           let meetingSummaryFailureSubtype {
            rows.append(
                QuillUserIssueDetailsRow(
                    label: localizedCatalogString(
                        "Failure reason",
                        language: language,
                        bundle: bundle
                    ),
                    value: meetingSummaryFailureSubtype.localizedDetailsValue(
                        language: language,
                        bundle: bundle
                    )
                )
            )
        }
        if let localBackend, !localBackend.isEmpty {
            rows.append(
                QuillUserIssueDetailsRow(
                    label: localizedCatalogString("Local backend", language: language, bundle: bundle),
                    value: localBackend
                )
            )
        }
        if let processExitCode {
            rows.append(
                QuillUserIssueDetailsRow(
                    label: localizedCatalogString("Process exit code", language: language, bundle: bundle),
                    value: String(processExitCode)
                )
            )
        }
        if let retryExhausted {
            rows.append(
                QuillUserIssueDetailsRow(
                    label: localizedCatalogString("Retry attempts exhausted", language: language, bundle: bundle),
                    value: localizedCatalogString(
                        retryExhausted ? "Yes" : "No",
                        language: language,
                        bundle: bundle
                    )
                )
            )
        }
        return rows
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLString: String) {
        guard !base64URLString.isEmpty,
              base64URLString.unicodeScalars.allSatisfy({ scalar in
                  CharacterSet.alphanumerics.contains(scalar)
                      || scalar == "-"
                      || scalar == "_"
              }) else {
            return nil
        }
        var base64 = base64URLString
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }
}
