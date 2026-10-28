import Foundation
import QuillUserIssueCore

enum MeetingSummaryIssueAction: Equatable {
    case retrySummary
    case recovery(QuillUserRecoveryAction)

    static func resolve(
        _ presentation: QuillUserIssuePresentation
    ) -> MeetingSummaryIssueAction {
        switch presentation.recoveryAction {
        case .none, .retryTranscription, .retryPostProcessing:
            return .retrySummary
        default:
            return .recovery(presentation.recoveryAction)
        }
    }
}

extension QuillUserIssueRecord {
    func presentation(
        language: String = preferredLocalizedStringLanguage(),
        bundle: Bundle = .main
    ) -> QuillUserIssuePresentation {
        presentation(localize: QuillUserIssueLocalizer(
            string: { localizedCatalogString($0, language: language, bundle: bundle) },
            seconds: { localizedCatalogFormat("%g seconds", $0, language: language, bundle: bundle) }
        ))
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
