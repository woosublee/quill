import Foundation
import QuillProviderCore

/// A withdrawal confirmation in Settings › Models (#723): for a Withdraw
/// row, or for clearing a key that goes to an agreed provider. It carries
/// what the confirmation was asked for, so answering it never reads state
/// that changed while it was up.
struct CloudConsentWithdrawalPrompt: Identifiable, Equatable {
    let id = UUID()
    let target: CloudConsentTargets.Target
    /// The key field whose clearing asked; nil for a Withdraw row.
    let clearedField: CloudConsentTargets.KeyField?
    /// The transcription URL saved with the cleared key (the Save button
    /// saves both fields), saved too once the withdrawal is done. Nil when
    /// it wasn't changed, or only the key was committed.
    var transcriptionURLToSave: String?

    init(
        target: CloudConsentTargets.Target,
        clearedField: CloudConsentTargets.KeyField? = nil,
        transcriptionURLToSave: String? = nil
    ) {
        self.target = target
        self.clearedField = clearedField
        self.transcriptionURLToSave = clearedField == .transcription ? transcriptionURLToSave : nil
    }

    /// The URL the Save button saves with a cleared transcription key, or
    /// nil when it matches the saved one.
    static func transcriptionURLToSave(typed: String, saved: String) -> String? {
        let typed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed == saved ? nil : typed
    }

    /// Whether saving `url` as the transcription URL sends no saved key to a
    /// provider without consent, so it can be saved without asking.
    static func savesWithoutConsent(_ url: String, in appState: AppState) -> Bool {
        var proposed = appState.cloudConsentTargets
        proposed.transcriptionAPIURL = url
        return proposed.unconsented(in: appState.cloudConsent).isEmpty
    }

    /// Where a refusal while recording or transcribing says why the key
    /// stays: under the key that was cleared, or under the consent rows for
    /// their Withdraw button, which may clear both keys.
    var busyPlace: CloudConsentBusyPlace {
        switch clearedField {
        case .main?: return .mainKey
        case .transcription?: return .transcriptionKey
        case nil: return .consentRows
        }
    }
}

/// Where Settings says a withdrawal waits for recording or transcribing to
/// end (#723).
enum CloudConsentBusyPlace: Equatable {
    case mainKey
    case transcriptionKey
    case consentRows

    /// Shown only while work is still running, so the message never outlasts
    /// the work even when Settings didn't see it end (it forgets the place
    /// when it does).
    func isShown(at place: Self, isLocked: Bool) -> Bool {
        self == place && isLocked
    }
}
