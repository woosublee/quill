import Foundation

enum QuillUserIssueCode: String, Codable, CaseIterable, Sendable {
    case networkUnavailable = "network-unavailable"
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
    case localAIModelUnavailable = "local-ai-model-unavailable"
    case localAIStartFailed = "local-ai-start-failed"
    case localAIProcessExited = "local-ai-process-exited"
    case unknown
    case legacy
}

enum QuillUserIssueSeverity: String, Codable, Equatable, Sendable {
    case error
    case warning
}

struct QuillUserIssueContext: Codable, Equatable, Sendable {
    let httpStatus: Int?
    let providerHost: String?
    let modelID: String?
    let localBackend: String?
    let processExitCode: Int32?
    let retryExhausted: Bool?

    init(
        httpStatus: Int? = nil,
        providerHost: String? = nil,
        modelID: String? = nil,
        localBackend: String? = nil,
        processExitCode: Int32? = nil,
        retryExhausted: Bool? = nil
    ) {
        self.httpStatus = httpStatus
        self.providerHost = providerHost
        self.modelID = modelID
        self.localBackend = localBackend
        self.processExitCode = processExitCode
        self.retryExhausted = retryExhausted
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
        switch code {
        case .authenticationFailed, .quotaExceeded,
             .providerConfigurationInvalid:
            return .openProviderSettings
        case .localRuntimeMissing, .localModelMissing,
             .localDependencyMissing, .localAIModelUnavailable:
            return .openModelsSettings
        case .microphonePermissionDenied:
            return .openMicrophoneSettings
        case .speechRecognitionPermissionDenied:
            return .openSpeechRecognitionSettings
        case .screenRecordingPermissionDenied:
            return .openScreenRecordingSettings
        case .postProcessingGuardFallback:
            return .none
        case .networkUnavailable, .requestTimedOut, .rateLimited,
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
        let copy = code.copy
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
            detailsRows: context.detailsRows(language: language, bundle: bundle),
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
            case .notConnectedToInternet, .networkConnectionLost,
                 .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
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
}

private extension QuillUserIssueCode {
    var defaultSeverity: QuillUserIssueSeverity {
        switch self {
        case .postProcessingFailed, .postProcessingRateLimited,
             .postProcessingGuardFallback, .localAIModelUnavailable,
             .localAIStartFailed, .localAIProcessExited:
            return .warning
        default:
            return .error
        }
    }

    var copy: QuillUserIssueCopy {
        switch self {
        case .networkUnavailable:
            return QuillUserIssueCopy(
                titleKey: "No network connection",
                bodyKey: "Quill could not reach the transcription service because this Mac appears to be offline.",
                suggestionKey: "Check your internet connection, then try again."
            )
        case .requestTimedOut:
            return QuillUserIssueCopy(
                titleKey: "Transcription timed out",
                bodyKey: "The transcription service did not respond in time.",
                suggestionKey: "Try again. If this keeps happening, check the provider status or choose another configured model."
            )
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
            return QuillUserIssueCopy(
                titleKey: "Transcript cleanup was skipped",
                bodyKey: "Quill kept the original transcript because cleanup could not complete.",
                suggestionKey: "You can use the transcript as-is or try cleanup again later."
            )
        case .postProcessingRateLimited:
            return QuillUserIssueCopy(
                titleKey: "Transcript cleanup is temporarily limited",
                bodyKey: "Quill kept the original transcript because the model is rate-limited.",
                suggestionKey: "Wait a moment and try cleanup again."
            )
        case .postProcessingGuardFallback:
            return QuillUserIssueCopy(
                titleKey: "Original transcript kept",
                bodyKey: "Quill detected that cleanup may have changed the intended meaning.",
                suggestionKey: "Review the original transcript before using it."
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

private extension QuillUserIssueContext {
    func detailsRows(language: String, bundle: Bundle) -> [QuillUserIssueDetailsRow] {
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
        if let modelID, !modelID.isEmpty {
            rows.append(
                QuillUserIssueDetailsRow(
                    label: localizedCatalogString("Model", language: language, bundle: bundle),
                    value: modelID
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
