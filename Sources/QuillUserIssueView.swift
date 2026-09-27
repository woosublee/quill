import SwiftUI

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

    /// A small centered card for a note with nothing else to show.
    private var fullView: some View {
        VStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(accentColor)
                .frame(width: 40, height: 40)
                .background(accentColor.opacity(0.12), in: Circle())

            Text(presentation.title)
                .font(.system(size: 14, weight: .semibold))
                .multilineTextAlignment(.center)

            Text(presentation.body)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                actionButton
                detailsButton
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
        .frame(maxWidth: 420)
        .background(issueSurface(cornerRadius: 14))
        .frame(maxWidth: .infinity)
    }

    /// One line above a note's content: title, the reason when it fits in
    /// full, and one action. A reason that would be cut off is left to the
    /// info popover instead of showing half a sentence.
    private var bannerView: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accentColor)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    bannerTitle
                    Text(presentation.body)
                        .font(.system(size: 12))
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
            actionButton
            detailsButton
            dismissButton
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(issueSurface(cornerRadius: 9))
    }

    private var bannerTitle: some View {
        Text(presentation.title)
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1)
            .truncationMode(.tail)
    }

    /// A compact box inside a settings form.
    private var inlineView: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accentColor)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.title)
                    .font(.system(size: 12, weight: .semibold))
                Text(presentation.body)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            actionButton
            detailsButton
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(issueSurface(cornerRadius: 8))
    }

    private func issueSurface(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color.primary.opacity(0.045))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
    }

    @ViewBuilder
    private var dismissButton: some View {
        if let onDismiss {
            Button(action: onDismiss) {
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
           actionTitleOverride != nil || presentation.recoveryAction != .none {
            Button(action: action) {
                Text(localizedCatalogString(actionTitleOverride ?? actionTitle))
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.primary.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .fixedSize()
        }
    }

    private var iconName: String {
        presentation.severity == .warning
            ? "exclamationmark.triangle.fill"
            : "exclamationmark.circle.fill"
    }

    /// Muted amber for warnings and a softened red for errors, so severity
    /// reads from the icon without tinting the whole surface.
    private var accentColor: Color {
        presentation.severity == .warning
            ? Color(red: 0.95, green: 0.70, blue: 0.36)
            : Color(red: 1.0, green: 0.48, blue: 0.44)
    }

    private var actionTitle: String {
        let key: String
        switch presentation.recoveryAction {
        case .retryTranscription:
            key = "Retry transcription"
        case .retryPostProcessing:
            key = "Retry Post-processing"
        case .openModelsSettings:
            key = "Open Models Settings"
        case .openProviderSettings:
            key = "Open Provider Settings"
        case .openMicrophoneSettings:
            key = "Open Microphone Settings"
        case .openSpeechRecognitionSettings:
            key = "Open Speech Recognition Settings"
        case .openScreenRecordingSettings:
            key = "Open Screen Recording Settings"
        case .none:
            key = ""
        }
        return key
    }
}

/// A quiet, dismissible line for an outcome that needs no action, such as
/// cleanup having nothing to change.
struct QuillInfoNotice: View {
    let text: String
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 11, weight: .medium))
            Text(text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
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
