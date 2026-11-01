import SwiftUI
import QuillDesignTokens

// A settings row with a two-line label and one button on the right, the same
// on the Mac and the iPhone: the consent rows (the provider, then when it was
// agreed to, with Withdraw or Agree…). It is drawn only from the design
// tokens; each app passes its own localized strings and the action. The
// platforms differ only where they must: the Mac's button is a small bordered
// one, and the iPhone's is a list row's text button with a 44 pt touch area.

/// A row's second line: plain, or a state that needs the person's attention
/// (a key saved before consent was asked).
public enum QuillTwoLineActionRowTone: Sendable {
    case secondary
    case attention
}

/// The row's button: a destructive one (Withdraw), or the one way forward
/// (Agree…).
public enum QuillTwoLineActionRowButton: Sendable {
    case destructive
    case prominent
}

public struct QuillTwoLineActionRow: View {
    let title: String
    let detail: String
    let tone: QuillTwoLineActionRowTone
    let actionTitle: String
    let actionKind: QuillTwoLineActionRowButton
    let isActionDisabled: Bool
    let action: () -> Void

    public init(
        title: String,
        detail: String,
        tone: QuillTwoLineActionRowTone = .secondary,
        actionTitle: String,
        actionKind: QuillTwoLineActionRowButton,
        isActionDisabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.detail = detail
        self.tone = tone
        self.actionTitle = actionTitle
        self.actionKind = actionKind
        self.isActionDisabled = isActionDisabled
        self.action = action
    }

    public var body: some View {
        HStack(spacing: QuillSpacing.space12) {
            VStack(alignment: .leading, spacing: QuillSpacing.space2) {
                Text(title)
                    .quillTextStyle(.body)
                    .foregroundStyle(.primary)
                Text(detail)
                    .quillTextStyle(.caption)
                    .foregroundStyle(tone == .attention ? QuillColor.statusProcessing : Color.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            button
                .disabled(isActionDisabled)
        }
        #if os(iOS)
        .frame(minHeight: QuillControlSize.touchMin)
        #endif
    }

    @ViewBuilder
    private var button: some View {
        let role: ButtonRole? = actionKind == .destructive ? .destructive : nil
        #if os(macOS)
        switch actionKind {
        case .destructive:
            Button(actionTitle, role: role, action: action)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .foregroundStyle(QuillColor.statusRecording)
        case .prominent:
            Button(actionTitle, role: role, action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        #else
        // In a list row, a borderless button keeps the row itself from
        // becoming one big button.
        Button(actionTitle, role: role, action: action)
            .buttonStyle(.borderless)
            .frame(minHeight: QuillControlSize.touchMin)
        #endif
    }
}
