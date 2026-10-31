import QuillUserIssueCore
import SwiftUI
import QuillDesignTokens

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
        VStack(spacing: QuillSpacing.space8) {
            // The 64 pt issue disc and its 10% tint have no token yet (#736).
            Image(systemName: iconName)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(accentColor)
                .frame(width: 64, height: 64)
                .background(accentColor.opacity(0.1), in: Circle())
                .padding(.bottom, QuillSpacing.space4)

            Text(presentation.title)
                .quillTextStyle(.emptyTitle)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text(presentation.body)
                .quillTextStyle(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: QuillSpacing.space6) {
                actionButton
                secondaryActionButton
                detailsButton
            }
            .padding(.top, QuillSpacing.space6)
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

/// A banner or issue row button's chrome: a primary 8% fill (no token yet,
/// #736) and a 1 pt `hairline` edge, on `radius-6`.
private struct QuillBannerButtonSurface: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        RoundedRectangle(cornerRadius: QuillRadius.radius6)
            .fill(Color.primary.opacity(0.08))
            .overlay(
                RoundedRectangle(cornerRadius: QuillRadius.radius6)
                    .strokeBorder(QuillColor.hairline.color(for: colorScheme), lineWidth: 1)
            )
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

/// A one-line status banner in the shared issue look, for notes that are
/// not tied to an issue record (for example, a summary's review reminders).
/// The detail shows beside the title when it fits, and as a tooltip always.
extension View {
    /// The shared banner look: a light fill, a hairline, and a soft shadow.
    func quillBannerBackground() -> some View {
        background(QuillBannerSurface(cornerRadius: QuillRadius.radius9))
    }
}

/// The surface behind every banner and inline issue row: `fill-banner`, a
/// 1 pt `hairline-strong` edge, and `shadow-banner`.
struct QuillBannerSurface: View {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(QuillColor.fillBanner.color(for: colorScheme))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(QuillColor.hairlineStrong.color(for: colorScheme), lineWidth: 1)
            )
            .quillShadow(.banner)
    }
}

struct QuillStatusBanner: View {
    let systemImage: String
    let tint: Color
    let title: String
    let detail: String
    var expansion: QuillBannerExpansion?
    var onDismiss: (() -> Void)?

    static let warningTint = QuillColor.issueWarning

    var body: some View {
        HStack(spacing: QuillSpacing.space8) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            if let expansion {
                titleText
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: spokenText))
                Spacer(minLength: 0)
                QuillBannerExpansionButton(expansion: expansion)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: QuillSpacing.space8) {
                        titleText
                        Text(detail)
                            .quillTextStyle(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 0) {
                        titleText
                        Spacer(minLength: 0)
                    }
                }
                // Title and detail read as one element; the close button
                // stays a separate control.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: spokenText))
            }
            if let onDismiss {
                QuillBannerDismissButton(action: onDismiss)
            }
        }
        .padding(.leading, QuillSpacing.space10)
        .padding(.trailing, onDismiss == nil ? QuillSpacing.space10 : QuillSpacing.space6)
        // 7 is off the spacing scale (#736); it stays a literal for now.
        .padding(.vertical, onDismiss == nil ? 7 : QuillSpacing.space6)
        .quillBannerBackground()
        .help(Text(verbatim: detail))
    }

    private var spokenText: String { "\(title) \(detail)" }

    private var titleText: some View {
        Text(title)
            .quillTextStyle(.bannerTitle)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

/// Lets the first banner of a group reveal or hide the rest.
struct QuillBannerExpansion {
    let hiddenCount: Int
    let isExpanded: Bool
    let toggle: () -> Void
}

/// The "+N" / "Show Less" pill on the first banner of a group.
struct QuillBannerExpansionButton: View {
    let expansion: QuillBannerExpansion

    var body: some View {
        Button(action: expansion.toggle) {
            Group {
                if expansion.isExpanded {
                    Text("Show Less")
                } else {
                    Text(verbatim: "+\(expansion.hiddenCount)")
                }
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            // 7 and the primary 8% fill have no token yet (#736).
            .padding(.horizontal, 7)
            .padding(.vertical, QuillSpacing.space2)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(expansion.isExpanded
            ? localizedCatalogString("Show Less")
            : localizedCatalogString("Show All Notices"))
        .accessibilityLabel(expansion.isExpanded
            ? localizedCatalogString("Show Less")
            : localizedCatalogString("Show All Notices"))
    }
}

/// The close button shared by every one-line banner.
struct QuillBannerDismissButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(localizedCatalogString("Dismiss"))
    }
}
