import QuillUserIssueCore
import SwiftUI
import QuillDesignTokens
import QuillNoteUI

enum QuillUserIssueViewStyle {
    case full
    case warningBanner
    case inline
}

struct QuillUserIssueView: View {
    let presentation: QuillUserIssuePresentation
    var style: QuillUserIssueViewStyle = .full
    var action: (() -> Void)?
    var actionTitleOverride: String?
    // Only meaningful for .warningBanner: when non-nil, a small close button
    // renders at the end of the banner. The centered error card (.full /
    // .inline styles) never passes this, so it never gets a dismiss control.
    var onDismiss: (() -> Void)?
    // Only meaningful for .warningBanner: set on the first banner of a
    // group to show a "+N" pill that reveals the rest.
    var expansion: QuillBannerExpansion?
    // A different symbol and tint for a state that is not an error, such as
    // a recovered recording.
    var systemImageOverride: String?
    var tintOverride: Color?
    // Only meaningful for .full: a second action beside the first, such as
    // Open Folder next to Recover Again.
    var secondaryAction: (() -> Void)?
    var secondaryActionTitle: String?
    var actionDisabled = false
    var secondaryActionDisabled = false

    @State private var showsDetails = false

    var body: some View {
        switch style {
        case .full:
            fullView
        case .warningBanner:
            bannerView
        case .inline:
            inlineView
        }
    }

    // All three styles share one look: a neutral surface with a hairline
    // border, severity only in the icon color, one neutral action, and the
    // suggestion and diagnostics behind an info popover.

    /// A centered empty state for a note with nothing else to show, drawn
    /// like the app's other empty states: no surface, just the icon, the
    /// title, one line, and the action.
    private var fullView: some View {
        VStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(accentColor)
                .frame(width: 64, height: 64)
                .background(accentColor.opacity(0.1), in: Circle())
                .padding(.bottom, 4)

            Text(presentation.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text(presentation.body)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                actionButton
                secondaryActionButton
                detailsButton
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: 380)
        .frame(maxWidth: .infinity)
    }

    /// One line above a note's content: title, the reason when it fits in
    /// full, and one action. A reason that would be cut off is left to the
    /// info popover instead of showing half a sentence.
    private var bannerView: some View {
        HStack(spacing: QuillSpacing.space8) {
            Image(systemName: iconName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accentColor)
            if let expansion {
                bannerTitle
                Spacer(minLength: 0)
                QuillBannerExpansionButton(expansion: expansion)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: QuillSpacing.space8) {
                        bannerTitle
                        Text(presentation.body)
                            .quillTextStyle(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 0) {
                        bannerTitle
                        Spacer(minLength: 0)
                    }
                }
            }
            actionButton
            detailsButton
            dismissButton
        }
        .padding(.leading, QuillSpacing.space10)
        .padding(.trailing, QuillSpacing.space6)
        .padding(.vertical, QuillSpacing.space6)
        .background(QuillBannerSurface(cornerRadius: QuillRadius.radius9))
    }

    private var bannerTitle: some View {
        Text(presentation.title)
            .quillTextStyle(.bannerTitle)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    /// A compact box inside a settings form.
    private var inlineView: some View {
        HStack(alignment: .top, spacing: QuillSpacing.space8) {
            Image(systemName: iconName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accentColor)
                .padding(.top, QuillSpacing.space2)
            VStack(alignment: .leading, spacing: QuillSpacing.space2) {
                Text(presentation.title)
                    .quillTextStyle(.bannerTitle)
                Text(presentation.body)
                    .quillTextStyle(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            actionButton
            detailsButton
        }
        .padding(.horizontal, QuillSpacing.space10)
        .padding(.vertical, QuillSpacing.space8)
        .background(QuillBannerSurface(cornerRadius: QuillRadius.radius8))
    }

    @ViewBuilder
    private var dismissButton: some View {
        if let onDismiss {
            QuillBannerDismissButton(action: onDismiss)
        }
    }

    /// The one-line banner can truncate its reason, so its popover repeats it.
    private var showsBodyInDetails: Bool {
        style == .warningBanner && !presentation.body.isEmpty
    }

    private var hasDetails: Bool {
        showsBodyInDetails
            || !presentation.suggestion.isEmpty
            || !presentation.detailsRows.isEmpty
    }

    /// The suggestion and diagnostic rows, behind an info button.
    @ViewBuilder
    private var detailsButton: some View {
        if hasDetails {
            Button {
                showsDetails.toggle()
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Issue Details")
            .accessibilityLabel(localizedCatalogString("Issue Details"))
            .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
                detailsContent
            }
        }
    }

    private var detailsContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsBodyInDetails {
                Text(presentation.body)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !presentation.suggestion.isEmpty {
                Text(presentation.suggestion)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !presentation.detailsRows.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    ForEach(Array(presentation.detailsRows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            Text(row.label)
                                .foregroundStyle(.secondary)
                            Text(row.value)
                                .textSelection(.enabled)
                        }
                    }
                }
                .font(.system(size: 11))
            }
        }
        .padding(12)
        .frame(width: 300, alignment: .leading)
    }

    @ViewBuilder
    private var actionButton: some View {
        if let action,
           let title = actionTitleOverride ?? presentation.recoveryAction.titleKey {
            actionButton(
                title: title,
                isDisabled: actionDisabled,
                action: action
            )
        }
    }

    @ViewBuilder
    private var secondaryActionButton: some View {
        if let secondaryAction, let secondaryActionTitle {
            actionButton(
                title: secondaryActionTitle,
                isDisabled: secondaryActionDisabled,
                action: secondaryAction
            )
        }
    }

    private func actionButton(
        title: String,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(localizedCatalogString(title))
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
                .padding(.horizontal, QuillSpacing.space9)
                .padding(.vertical, QuillSpacing.space3)
                .background(QuillBannerButtonSurface())
                .contentShape(RoundedRectangle(cornerRadius: QuillRadius.radius6))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.5 : 1)
    }

    private var iconName: String {
        if let systemImageOverride { return systemImageOverride }
        return presentation.severity == .warning
            ? "exclamationmark.triangle.fill"
            : "exclamationmark.circle.fill"
    }

    /// Muted amber for warnings and a softened red for errors, so severity
    /// reads from the icon without tinting the whole surface.
    private var accentColor: Color {
        if let tintOverride { return tintOverride }
        return presentation.severity == .warning
            ? QuillColor.issueWarning
            : QuillColor.issueError
    }

}

/// A quiet, dismissible line for an outcome that needs no action, such as
/// cleanup having nothing to change.
struct QuillInfoNotice: View {
    let text: String
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(spacing: QuillSpacing.space6) {
            Image(systemName: "info.circle")
                .font(.system(size: 11, weight: .medium))
            Text(text)
                .quillTextStyle(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: QuillSpacing.space6)
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 20, height: 20)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(localizedCatalogString("Dismiss"))
            }
        }
        .foregroundStyle(.secondary)
    }
}

/// The text the shared banner's own controls show, in this app's language.
extension NoteBannerStrings {
    static var mac: NoteBannerStrings {
        NoteBannerStrings(
            showLess: localizedCatalogString("Show Less"),
            showAllNotices: localizedCatalogString("Show All Notices"),
            dismiss: localizedCatalogString("Dismiss")
        )
    }
}

/// A banner or issue row button's chrome (`NoteBannerButtonSurface`).
private typealias QuillBannerButtonSurface = NoteBannerButtonSurface

/// The surface behind every banner and inline issue row
/// (`NoteBannerSurface`, shared with the iPhone).
typealias QuillBannerSurface = NoteBannerSurface

/// Lets the first banner of a group reveal or hide the rest.
typealias QuillBannerExpansion = NoteBannerExpansion

extension View {
    /// The shared banner look: a light fill, a hairline, and a soft shadow.
    func quillBannerBackground() -> some View {
        noteBannerBackground()
    }
}

/// A one-line status banner in the shared issue look, for notes that are
/// not tied to an issue record (for example, a summary's review reminders).
/// The detail shows beside the title when it fits, and as a tooltip always.
/// Drawn by the shared `NoteBanner` (#744).
struct QuillStatusBanner: View {
    let systemImage: String
    let tint: Color
    let title: String
    let detail: String
    var expansion: QuillBannerExpansion?
    var onDismiss: (() -> Void)?

    static let warningTint = QuillColor.issueWarning

    var body: some View {
        NoteBanner(
            systemImage: systemImage,
            tint: tint,
            title: title,
            detail: detail,
            strings: .mac,
            expansion: expansion,
            onDismiss: onDismiss
        )
    }
}

/// The "+N" / "Show Less" pill on the first banner of a group.
struct QuillBannerExpansionButton: View {
    let expansion: QuillBannerExpansion

    var body: some View {
        NoteBannerExpansionButton(expansion: expansion, strings: .mac)
    }
}

/// The close button shared by every one-line banner.
struct QuillBannerDismissButton: View {
    let action: () -> Void

    var body: some View {
        NoteBannerDismissButton(label: localizedCatalogString("Dismiss"), action: action)
    }
}
