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

    private var fullView: some View {
        VStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 30, weight: .ultraLight))
                .foregroundStyle(accentColor)

            Text(presentation.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text(presentation.body)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            if !presentation.suggestion.isEmpty {
                Text(presentation.suggestion)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            detailsView
            actionButton
        }
        .frame(maxWidth: .infinity)
    }

    private var bannerView: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(accentColor)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(presentation.title)
                    .font(.caption.weight(.semibold))
                Text(presentation.body)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)
            actionButton
        }
        .padding(10)
        .background(
            accentColor.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(accentColor.opacity(0.15), lineWidth: 1)
        )
    }

    private var inlineView: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(presentation.title, systemImage: iconName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(accentColor)
            Text(presentation.body)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !presentation.suggestion.isEmpty {
                Text(presentation.suggestion)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            detailsView
            actionButton
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var detailsView: some View {
        if !presentation.detailsRows.isEmpty {
            DisclosureGroup("Details") {
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
                .font(.caption2)
                .padding(.top, 6)
            }
            .font(.caption)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if let action, presentation.recoveryAction != .none {
            Button(actionTitle, action: action)
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    private var iconName: String {
        presentation.severity == .warning
            ? "exclamationmark.triangle"
            : "exclamationmark.triangle.fill"
    }

    private var accentColor: Color {
        presentation.severity == .warning ? .orange : .red
    }

    private var actionTitle: String {
        let key: String
        switch presentation.recoveryAction {
        case .retryTranscription:
            key = "Retry transcription"
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
        return localizedCatalogString(key)
    }
}
