import Foundation

public enum QuillUserRecoveryAction: Equatable, Sendable {
    case retryTranscription
    /// Re-run only post-processing on the stored raw transcript.
    case retryPostProcessing
    case openModelsSettings
    case openProviderSettings
    case openMicrophoneSettings
    case openSpeechRecognitionSettings
    case openScreenRecordingSettings
    case none
}

extension QuillUserRecoveryAction {
    /// The catalog key for the recovery button, or nil when there is no action.
    public var titleKey: String? {
        switch self {
        case .retryTranscription: "Retry transcription"
        case .retryPostProcessing: "Retry Post-processing"
        case .openModelsSettings: "Open Models Settings"
        case .openProviderSettings: "Open Provider Settings"
        case .openMicrophoneSettings: "Open Microphone Settings"
        case .openSpeechRecognitionSettings: "Open Speech Recognition Settings"
        case .openScreenRecordingSettings: "Open Screen Recording Settings"
        case .none: nil
        }
    }
}

public struct QuillUserIssueDetailsRow: Equatable, Sendable {
    public let label: String
    public let value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

public struct QuillUserIssuePresentation: Equatable, Sendable {
    public let title: String
    public let body: String
    public let suggestion: String
    public let compactMessage: String
    public let detailsRows: [QuillUserIssueDetailsRow]
    public let recoveryAction: QuillUserRecoveryAction
    public let severity: QuillUserIssueSeverity

    public init(
        title: String,
        body: String,
        suggestion: String,
        compactMessage: String,
        detailsRows: [QuillUserIssueDetailsRow],
        recoveryAction: QuillUserRecoveryAction,
        severity: QuillUserIssueSeverity
    ) {
        self.title = title
        self.body = body
        self.suggestion = suggestion
        self.compactMessage = compactMessage
        self.detailsRows = detailsRows
        self.recoveryAction = recoveryAction
        self.severity = severity
    }
}

/// Translates the shared copy keys with the app's own String Catalog (the
/// Mac's `localizedCatalogString`, the iPhone's `String(localized:)`).
public struct QuillUserIssueLocalizer: Sendable {
    public let string: @Sendable (String) -> String
    /// Formats a duration in seconds, like the catalog's "%g seconds".
    public let seconds: @Sendable (Double) -> String

    public init(string: @escaping @Sendable (String) -> String, seconds: @escaping @Sendable (Double) -> String) {
        self.string = string
        self.seconds = seconds
    }
}

extension QuillUserIssueRecord {
    public var recoveryAction: QuillUserRecoveryAction {
        if context.operation == .postProcessing,
           context.postProcessingFailureReason == .contextBudgetExceeded {
            return .none
        }
        // Only cleanup failed; the transcript is fine, so a retry re-runs
        // cleanup alone. Fixes that need settings keep their settings action.
        let action = defaultRecoveryAction
        if context.operation == .postProcessing, action == .retryTranscription {
            return .retryPostProcessing
        }
        return action
    }

    private var defaultRecoveryAction: QuillUserRecoveryAction {
        switch code {
        case .authenticationFailed, .quotaExceeded,
             .providerConfigurationInvalid:
            return .openProviderSettings
        case .localRuntimeMissing, .localModelMissing,
             .localDependencyMissing, .localAIModelUnavailable,
             .meetingSummaryLanguageUnavailable, .appleSpeechOnDeviceUnavailable:
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

    /// The title, body, suggestion, and detail rows to show for this issue,
    /// translated by `localize`.
    public func presentation(localize: QuillUserIssueLocalizer) -> QuillUserIssuePresentation {
        let copy = code.copy(for: context)
        let title = localize.string(copy.titleKey)
        return QuillUserIssuePresentation(
            title: title,
            body: localize.string(copy.bodyKey),
            suggestion: localize.string(copy.suggestionKey),
            compactMessage: title,
            detailsRows: context.detailsRows(for: code, localize: localize),
            recoveryAction: recoveryAction,
            severity: severity
        )
    }
}

extension QuillUserIssueCode {
    /// The catalog keys for this issue's copy. Each app translates the same
    /// keys with its own String Catalog.
    public func copy(
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
        case .appleSpeechOnDeviceUnavailable:
            return QuillUserIssueCopy(
                titleKey: "Apple Speech can't be used for this language",
                bodyKey: "This language can't be transcribed on this Mac with Apple Speech.",
                suggestionKey: "Choose Native Whisper or another model in Models settings."
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

public struct QuillUserIssueCopy: Equatable, Sendable {
    public let titleKey: String
    public let bodyKey: String
    public let suggestionKey: String

    public init(titleKey: String, bodyKey: String, suggestionKey: String) {
        self.titleKey = titleKey
        self.bodyKey = bodyKey
        self.suggestionKey = suggestionKey
    }
}

private extension MeetingSummaryFailureSubtype {
    func localizedDetailsValue(_ localize: QuillUserIssueLocalizer) -> String {
        let key: String
        switch self {
        case .emptyOutput:
            key = "Empty output"
        case .responseEnvelope:
            key = "Response envelope"
        case .jsonSchema:
            key = "Summary format"
        case .outputTruncated:
            key = "Response cut off"
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
        return localize.string(key)
    }
}

private extension PostProcessingFailureReason {
    func localizedDetailsValue(_ localize: QuillUserIssueLocalizer) -> String {
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
        return localize.string(key)
    }
}

private extension QuillUserIssueContext {
    func detailsRows(
        for issueCode: QuillUserIssueCode,
        localize: QuillUserIssueLocalizer
    ) -> [QuillUserIssueDetailsRow] {
        var rows: [QuillUserIssueDetailsRow] = []
        if let httpStatus {
            rows.append(
                QuillUserIssueDetailsRow(
                    label: localize.string("HTTP status"),
                    value: String(httpStatus)
                )
            )
        }
        if let providerHost, !providerHost.isEmpty {
            rows.append(
                QuillUserIssueDetailsRow(
                    label: localize.string("Provider"),
                    value: providerHost
                )
            )
        }
        if let providerCode, !providerCode.isEmpty {
            rows.append(
                QuillUserIssueDetailsRow(
                    label: localize.string("Provider code"),
                    value: providerCode
                )
            )
        }
        if let modelID, !modelID.isEmpty {
            rows.append(
                QuillUserIssueDetailsRow(
                    label: localize.string("Model"),
                    value: modelID
                )
            )
        }
        if operation == .postProcessing {
            rows.append(
                QuillUserIssueDetailsRow(
                    label: localize.string("Operation"),
                    value: localize.string("Transcript cleanup")
                )
            )
            if let postProcessingFailureReason {
                rows.append(
                    QuillUserIssueDetailsRow(
                        label: localize.string("Failure reason"),
                        value: postProcessingFailureReason.localizedDetailsValue(localize)
                    )
                )
            }
            if let requestTimeoutSeconds,
               requestTimeoutSeconds.isFinite,
               requestTimeoutSeconds > 0 {
                let timeoutValue = localize.seconds(requestTimeoutSeconds)
                rows.append(
                    QuillUserIssueDetailsRow(
                        label: localize.string("Request timeout"),
                        value: timeoutValue
                    )
                )
            }
        }
        if issueCode == .meetingSummaryInvalidResponse,
           let meetingSummaryFailureSubtype {
            rows.append(
                QuillUserIssueDetailsRow(
                    label: localize.string("Failure reason"),
                    value: meetingSummaryFailureSubtype.localizedDetailsValue(localize)
                )
            )
        }
        if let localBackend, !localBackend.isEmpty {
            rows.append(
                QuillUserIssueDetailsRow(
                    label: localize.string("Local backend"),
                    value: localBackend
                )
            )
        }
        if let processExitCode {
            rows.append(
                QuillUserIssueDetailsRow(
                    label: localize.string("Process exit code"),
                    value: String(processExitCode)
                )
            )
        }
        if let retryExhausted {
            rows.append(
                QuillUserIssueDetailsRow(
                    label: localize.string("Retry attempts exhausted"),
                    value: localize.string(retryExhausted ? "Yes" : "No")
                )
            )
        }
        return rows
    }
}
