import Foundation
import QuillAITextCore
import QuillSummaryFormatCore
import QuillUserIssueCore

public enum MeetingSummaryLanguageError: Error, Equatable, Sendable {
    /// The spoken language is unknown, so the summary language can't follow it.
    case unavailable
}

/// The language a summary is written in, and the spoken language worked out
/// on the way when the note didn't have a reliable one.
public struct MeetingSummaryLanguageDecision: Equatable, Sendable {
    public let context: MeetingSummaryLanguageContext
    /// Set when the spoken language was worked out from the transcript (or
    /// the note had none). The caller stores it on the note.
    public let resolvedSpokenLanguage: SpokenLanguageResolution?

    public init(context: MeetingSummaryLanguageContext, resolvedSpokenLanguage: SpokenLanguageResolution?) {
        self.context = context
        self.resolvedSpokenLanguage = resolvedSpokenLanguage
    }

    /// The configured summary language comes first. Without one (an empty
    /// or unknown setting), the summary follows the spoken language. A
    /// spoken language guessed from the transcript, or one that was
    /// unavailable, is worked out again from the current transcript.
    public static func resolve(
        requestedOutputLanguage: String,
        spokenLanguage: SpokenLanguageResolution?,
        transcriptionLanguageCode: String,
        transcript: String
    ) throws -> MeetingSummaryLanguageDecision {
        let requested = requestedOutputLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        if let explicitCode = MeetingSummaryPromptLanguage.code(forSetting: requested) {
            return MeetingSummaryLanguageDecision(
                context: MeetingSummaryLanguageContext(
                    requestedOutputLanguage: requested,
                    appliedLanguageCode: explicitCode,
                    resolutionSource: .configured
                ),
                resolvedSpokenLanguage: nil
            )
        }
        let spoken: SpokenLanguageResolution
        let resolvesFromTranscript: Bool
        if let spokenLanguage,
           spokenLanguage.source != .transcriptInferred,
           spokenLanguage.source != .unavailable {
            spoken = spokenLanguage
            resolvesFromTranscript = false
        } else {
            spoken = SpokenLanguageResolver.resolve(
                requestedLanguageCode: transcriptionLanguageCode,
                engineLanguageCode: nil,
                transcript: transcript
            )
            resolvesFromTranscript = true
        }
        guard let code = spoken.languageCode else {
            throw MeetingSummaryLanguageError.unavailable
        }
        return MeetingSummaryLanguageDecision(
            context: MeetingSummaryLanguageContext(
                requestedOutputLanguage: "",
                appliedLanguageCode: code,
                resolutionSource: spoken.source
            ),
            resolvedSpokenLanguage: resolvesFromTranscript ? spoken : nil
        )
    }
}

/// The summary and attempt records both apps store after a summary run.
/// Each app decides when to store them and keeps its own checks for a
/// changed source.
public enum MeetingSummaryRecordBuilder {
    /// A new summary. Action items keep the done state they had in the
    /// previous summary.
    public static func successEnvelope(
        result: MeetingSummaryGenerationResult,
        sourceFingerprint: String,
        languageContext: MeetingSummaryLanguageContext,
        generatedAt: Date,
        previous: MeetingSummaryEnvelope?
    ) -> MeetingSummaryEnvelope {
        MeetingSummaryEnvelope(
            schemaVersion: MeetingSummaryEnvelope.currentSchemaVersion,
            promptVersion: result.promptVersion,
            generatedAt: generatedAt,
            sourceFingerprint: sourceFingerprint,
            modelID: result.modelID,
            backendKind: result.backendKind,
            languageContext: languageContext,
            evidenceVerification: result.evidenceVerification == .unverified ? .unverified : nil,
            content: result.draft.materialized()
        ).preservingCompletion(from: previous)
    }

    /// A succeeded attempt. A cloud result records the host it used, which
    /// for a cloud fallback of a local model isn't the configured one.
    public static func successAttempt(
        result: MeetingSummaryGenerationResult,
        configuredProviderHost: String?,
        languageContext: MeetingSummaryLanguageContext,
        sourceFingerprint: String,
        occurredAt: Date
    ) -> MeetingSummaryAttempt {
        MeetingSummaryAttempt(
            occurredAt: occurredAt,
            outcome: .succeeded,
            backendKind: result.backendKind,
            modelID: result.modelID,
            providerHost: result.backendKind == .cloud
                ? result.providerHost ?? configuredProviderHost
                : nil,
            language: languageContext,
            issue: nil,
            sourceFingerprint: sourceFingerprint
        )
    }

    /// A failed attempt with the configured backend and model. The host is
    /// kept only for the cloud.
    ///
    /// - Parameters:
    ///   - issue: the app's own record for an error only it knows about.
    ///     When nil, the record comes from `MeetingSummaryError` or
    ///     `MeetingSummaryLanguageError`, or is a general summary failure.
    ///   - severity: overrides the codes' default severity for a record
    ///     built here. A passed `issue` is stored as it is.
    public static func failureAttempt(
        error: Error,
        issue: QuillUserIssueRecord? = nil,
        backendKind: MeetingSummaryBackendKind,
        configuredModelID: String,
        configuredProviderHost: String?,
        languageContext: MeetingSummaryLanguageContext?,
        sourceFingerprint: String,
        occurredAt: Date,
        severity: QuillUserIssueSeverity? = nil
    ) -> MeetingSummaryAttempt {
        let modelID = (error as? MeetingSummaryError)?.effectiveModelID(fallback: configuredModelID)
            ?? configuredModelID
        let providerHost = backendKind == .cloud ? configuredProviderHost : nil
        return MeetingSummaryAttempt(
            occurredAt: occurredAt,
            outcome: .failed,
            backendKind: backendKind,
            modelID: modelID,
            providerHost: providerHost,
            language: languageContext,
            issue: issue ?? failureIssue(
                for: error,
                providerHost: providerHost,
                backendKind: backendKind,
                modelID: modelID,
                severity: severity
            ),
            sourceFingerprint: sourceFingerprint
        )
    }

    private static func failureIssue(
        for error: Error,
        providerHost: String?,
        backendKind: MeetingSummaryBackendKind,
        modelID: String,
        severity: QuillUserIssueSeverity?
    ) -> QuillUserIssueRecord {
        let localBackend = backendKind == .local ? "Local AI" : nil
        if let summaryError = error as? MeetingSummaryError {
            return summaryError.userIssue(
                providerHost: providerHost,
                modelID: modelID,
                localBackend: localBackend,
                severity: severity
            )
        }
        if error as? MeetingSummaryLanguageError == .unavailable {
            return QuillUserIssueRecord(code: .meetingSummaryLanguageUnavailable, severity: severity)
        }
        return QuillUserIssueRecord(
            code: .meetingSummaryUnavailable,
            severity: severity,
            context: QuillUserIssueContext(
                providerHost: providerHost,
                modelID: modelID,
                localBackend: localBackend
            )
        )
    }
}
