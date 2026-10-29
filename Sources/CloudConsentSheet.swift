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
        sheet(item: request) { current in
            if let target = current.targets.first {
                CloudConsentSheet(
                    host: target.displayName,
                    cancelNoteKey: current.cancelNoteKey,
                    onAgree: {
                        request.wrappedValue = nil
                        if let next = current.remaining(appState: appState) {
                            // Swapping the item of a sheet that's still up
                            // may not show the new one on macOS, so this one
                            // closes first.
                            DispatchQueue.main.async { request.wrappedValue = next }
                        } else {
                            for agreed in current.agreed + [target] {
                                appState.grantCloudConsent(forBaseURL: agreed.baseURL)
                            }
                            current.onAgree()
                        }
                    },
                    onCancel: {
                        request.wrappedValue = nil
                        current.onCancel()
                    }
                )
            }
        }
    }
}

private struct CloudConsentSheet: View {
    let host: String
    let cancelNoteKey: String
    let onAgree: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(localizedCatalogFormat(CloudConsentCopy.titleFormatKey, host))
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Text(localizedCatalogString(CloudConsentCopy.bodyKey(mentionsScreenContext: true)))
                .fixedSize(horizontal: false, vertical: true)
            Text(
                localizedCatalogString(cancelNoteKey) + " "
                    + localizedCatalogString("You can withdraw consent anytime in Settings › Models.")
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(localizedCatalogString(CloudConsentCopy.cancelKey), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(localizedCatalogString(CloudConsentCopy.agreeKey), action: onAgree)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 420)
        .interactiveDismissDisabled()
    }
}
