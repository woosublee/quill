import SwiftUI
import QuillProviderCore

/// Asks for cloud consent before a key is saved (#693). One request can need
/// two providers (the main one and a separate transcription one); they're
/// asked one after the other, and cancelling either cancels the change.
/// Nothing is granted until every provider is agreed to. Agreeing checks the
/// settings again, since another window shares them: a provider the change
/// would now reach is asked about too.
struct CloudConsentRequest: Identifiable {
    let id = UUID()
    let targets: [CloudConsentTargets.Target]
    /// Providers already agreed to in this request, granted at the end.
    var agreed: [CloudConsentTargets.Target] = []
    /// What cancelling does: `CloudConsentCopy.cancelClearsKeyKey` or
    /// `CloudConsentCopy.cancelChangesNothingKey`.
    let cancelNoteKey: String
    /// The change being agreed to, checked again on the last Agree. Nil for
    /// agreeing to a key that's already saved.
    var change: ((inout CloudConsentTargets) -> Void)? = nil
    let onAgree: () -> Void
    let onCancel: () -> Void

    /// Applies `change` to the current settings and runs `apply` once every
    /// provider it would send to has consent. Returns nil when none needs
    /// asking, after running `apply`.
    @MainActor
    static func applying(
        _ change: @escaping (inout CloudConsentTargets) -> Void,
        appState: AppState,
        cancelNoteKey: String,
        apply: @escaping () -> Void,
        cancel: @escaping () -> Void
    ) -> CloudConsentRequest? {
        var proposed = appState.cloudConsentTargets
        change(&proposed)
        let targets = proposed.unconsented(in: appState.cloudConsent)
        guard !targets.isEmpty else {
            apply()
            return nil
        }
        return CloudConsentRequest(
            targets: targets,
            cancelNoteKey: cancelNoteKey,
            change: change,
            onAgree: apply,
            onCancel: cancel
        )
    }

    /// The request for the providers still to ask about once the first one
    /// is agreed to: the rest of this request, or any the change would reach
    /// now that the settings have changed. Nil when none is left.
    @MainActor
    fileprivate func remaining(appState: AppState) -> CloudConsentRequest? {
        let agreed = agreed + targets.prefix(1)
        var rest = Array(targets.dropFirst())
        if rest.isEmpty, let change {
            var proposed = appState.cloudConsentTargets
            change(&proposed)
            var ledger = appState.cloudConsent
            for target in agreed { ledger.grant(forBaseURL: target.baseURL) }
            rest = proposed.unconsented(in: ledger)
        }
        guard !rest.isEmpty else { return nil }
        return CloudConsentRequest(
            targets: rest,
            agreed: agreed,
            cancelNoteKey: cancelNoteKey,
            change: change,
            onAgree: onAgree,
            onCancel: onCancel
        )
    }
}

extension View {
    func cloudConsentSheet(_ request: Binding<CloudConsentRequest?>, appState: AppState) -> some View {
        modifier(CloudConsentDialog(request: request, appState: appState))
    }
}

/// The same system confirmation as withdrawing (#729 owner check), so
/// asking for consent and withdrawing it look alike. Closing it without a
/// button (Escape) cancels, as the Cancel button does.
private struct CloudConsentDialog: ViewModifier {
    @Binding var request: CloudConsentRequest?
    let appState: AppState
    /// The host the dialog was shown for, kept while it closes so the title
    /// doesn't lose it.
    @State private var host = ""
    /// The request a button already answered.
    @State private var answeredID: UUID?

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                Text(verbatim: localizedCatalogFormat(CloudConsentCopy.titleFormatKey, host)),
                isPresented: Binding(
                    get: { request != nil },
                    set: { isPresented in
                        guard !isPresented, let shown = request else { return }
                        // A button's action can run after this; only a close
                        // no button answered cancels.
                        DispatchQueue.main.async {
                            guard answeredID != shown.id, request?.id == shown.id else { return }
                            request = nil
                            shown.onCancel()
                        }
                    }
                ),
                titleVisibility: .visible,
                presenting: request
            ) { current in
                if let target = current.targets.first {
                    Button(localizedCatalogString(CloudConsentCopy.agreeKey)) {
                        agree(current, target: target)
                    }
                }
                Button(localizedCatalogString(CloudConsentCopy.cancelKey), role: .cancel) {
                    answeredID = current.id
                    request = nil
                    current.onCancel()
                }
            } message: { current in
                Text(
                    localizedCatalogString(CloudConsentCopy.bodyKey(mentionsScreenContext: true)) + "\n\n"
                        + localizedCatalogString(current.cancelNoteKey) + " "
                        + localizedCatalogString("You can withdraw consent anytime in Settings › Models.")
                )
            }
            .onChange(of: request?.id) { _ in
                if let name = request?.targets.first?.displayName { host = name }
            }
            .onAppear {
                if let name = request?.targets.first?.displayName { host = name }
            }
    }

    private func agree(_ current: CloudConsentRequest, target: CloudConsentTargets.Target) {
        answeredID = current.id
        request = nil
        if let next = current.remaining(appState: appState) {
            // The next provider's dialog shows once this one has closed;
            // swapping it while it's still up may not show the new one on
            // macOS.
            DispatchQueue.main.async { request = next }
        } else {
            for agreed in current.agreed + [target] {
                appState.grantCloudConsent(forBaseURL: agreed.baseURL)
            }
            current.onAgree()
        }
    }
}
