import SwiftUI
import QuillDesignTokens

// The "Calendar suggested title … Apply" row above a note, shared by the Mac
// and the iPhone (#832). Whether it shows and what Apply sets come from
// `CalendarTitleSuggestion` in QuillNoteCore. Each app passes its localized
// strings and the actions: Apply saves the title, and close dismisses the
// suggestion on every device (`NoteNoticeDismissals.Notice.calendarTitleSuggestion`).

public struct NoteCalendarTitleSuggestionRow: View {
    let label: String
    let title: String
    let applyLabel: String
    let dismissLabel: String
    let onApply: () -> Void
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    public init(
        label: String,
        title: String,
        applyLabel: String,
        dismissLabel: String,
        onApply: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.label = label
        self.title = title
        self.applyLabel = applyLabel
        self.dismissLabel = dismissLabel
        self.onApply = onApply
        self.onDismiss = onDismiss
    }

    public var body: some View {
        HStack(spacing: QuillSpacing.space10) {
            Image(systemName: "calendar")
                // The Mac row's literal sizes; they have no token yet (#736).
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.blue)
                .frame(width: 24, height: 24)
                .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                .accessibilityHidden(true)

            HStack(alignment: .firstTextBaseline, spacing: QuillSpacing.space8) {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)

            Button(applyLabel, action: onApply)
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
                .controlSize(.small)

            NoteBannerDismissButton(label: dismissLabel, action: onDismiss)
        }
        .padding(.horizontal, QuillSpacing.space10)
        .padding(.vertical, QuillSpacing.space8)
        .background(
            Color.blue.opacity(colorScheme == .dark ? 0.12 : 0.06),
            in: RoundedRectangle(cornerRadius: QuillRadius.radius10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: QuillRadius.radius10)
                .stroke(Color.blue.opacity(0.16), lineWidth: 1)
        )
    }
}
