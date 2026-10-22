import SwiftUI

struct LocalAIManagedModelResolver {
    struct Input: Equatable {
        let pendingModelID: String?
        let retainedModelID: String?
        let currentChoice: AIProcessingBackendChoice
        let retainedIsInstalling: Bool
        let retainedProgressIsCancelled: Bool
        let retainedHasIssue: Bool

        var retainedIsActionable: Bool {
            retainedIsInstalling
                || retainedProgressIsCancelled
                || retainedHasIssue
        }
    }

    struct Resolution: Equatable {
        let model: LocalAIModel?
        let reconciledRetainedModelID: String?
    }

    static func resolve(_ input: Input) -> Resolution {
        let pendingModel = input.pendingModelID.flatMap {
            LocalAIModelCatalog.model(id: $0)
        }
        let retainedModel = input.retainedModelID.flatMap {
            LocalAIModelCatalog.model(id: $0)
        }
        let currentModel: LocalAIModel?
        if case .localAI(let currentModelID) = input.currentChoice {
            currentModel = LocalAIModelCatalog.model(id: currentModelID)
        } else {
            currentModel = nil
        }

        let shouldRetain = retainedModel.map { model in
            pendingModel?.id == model.id
                || currentModel?.id == model.id
                || input.retainedIsActionable
        } ?? false
        let reconciledRetainedModelID = shouldRetain
            ? retainedModel?.id
            : nil
        let model = pendingModel
            ?? (shouldRetain ? retainedModel : nil)
            ?? currentModel

        return Resolution(
            model: model,
            reconciledRetainedModelID: reconciledRetainedModelID
        )
    }
}

enum LocalAIModelRowPresentation {
    case managed
    case cleanupOnly
}

struct LocalAIModelRowView: View {
    @EnvironmentObject var appState: AppState

    /// The AI feature this row selects for, or nil for transcription.
    let feature: AIProcessingFeature?
    let model: LocalAIModel
    let isSelected: Bool
    let presentation: LocalAIModelRowPresentation
    /// False under a fallback picker: downloading doesn't change the
    /// feature's primary model.
    let selectsOnDownload: Bool

    @State private var showDeleteConfirmation = false
    @State private var isHoveringProgress = false
    @FocusState private var isCancelFocused: Bool

    init(
        feature: AIProcessingFeature?,
        model: LocalAIModel,
        isSelected: Bool,
        presentation: LocalAIModelRowPresentation = .managed,
        selectsOnDownload: Bool = true
    ) {
        self.feature = feature
        self.model = model
        self.isSelected = isSelected
        self.presentation = presentation
        self.selectsOnDownload = selectsOnDownload
    }

    private var state: LocalAIModelInstallViewState {
        appState.localAIInstallState(for: model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                modelDescription
                    .frame(maxWidth: .infinity, alignment: .leading)

                actionView
            }

            if presentation == .managed, isPendingSelection {
                Text("This model will become active when the download finishes.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if presentation == .cleanupOnly {
                Text("This installed model is unavailable and cannot be used on this Mac.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let issue = state.issue {
                QuillUserIssueView(
                    presentation: issue.presentation(),
                    style: .inline
                )
            }
        }
        .padding(8)
        .background(
            isSelected
                ? Color.accentColor.opacity(0.08)
                : Color(nsColor: .controlBackgroundColor)
        )
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(
                    isSelected ? Color.accentColor.opacity(0.3) : Color.clear,
                    lineWidth: 1
                )
        )
        .accessibilityValue(
            localizedCatalogString(isSelected ? "Selected" : "Not selected")
        )
        .confirmationDialog(
            "Delete model?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Model", role: .destructive) {
                appState.deleteLocalAIModel(model)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the downloaded Local AI model. You can download it again later.")
        }
    }

    private func localizedFeatureName(_ feature: AIModelFeature) -> String {
        switch feature {
        case .postProcessing:
            localizedCatalogString("Post-processing")
        case .contextCapture:
            localizedCatalogString("Context")
        case .meetingSummary:
            localizedCatalogString("Meeting Summary")
        case .transcription:
            localizedCatalogString("Transcription")
        }
    }

    /// In the order Settings lists the features.
    private var supportedFeatureNames: [String] {
        [
            AIModelFeature.transcription,
            .postProcessing,
            .contextCapture,
            .meetingSummary
        ].compactMap { feature in
            model.capabilities.supports(feature)
                ? localizedFeatureName(feature)
                : nil
        }
    }

    private var modelDescription: some View {
        ModelRowDescription(
            name: model.displayName,
            approximateBytes: model.approximateBytes,
            description: model.localizedDescription(),
            featureNames: supportedFeatureNames,
            isSelected: isSelected
        )
    }

    @ViewBuilder
    private var actionView: some View {
        if presentation == .cleanupOnly {
            if state.status == .ready {
                installedActionView
            } else {
                Text("Unavailable")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else if state.isInstalling, state.progress.isCancelled {
            cancellingView
        } else if state.isInstalling {
            progressView
        } else if state.progress.isCancelled {
            downloadButton
        } else if state.status == .ready {
            installedActionView
        } else {
            downloadButton
        }
    }

    private var installedActionView: some View {
        HStack(spacing: 8) {
            Label("Installed", systemImage: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.green)
            Button {
                showDeleteConfirmation = true
            } label: {
                Image(systemName: "trash")
            }
            .font(.caption)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("Delete Model")
        }
    }

    private var isPendingSelection: Bool {
        // A fallback picked before its download runs once downloaded.
        guard selectsOnDownload else { return state.status != .ready }
        if let feature {
            return appState.pendingLocalAIModelID(for: feature) == model.id
        }
        return appState.pendingLocalAITranscriptionModelID == model.id
    }

    private var downloadButton: some View {
        Button("Download") {
            if feature == nil {
                appState.selectLocalAITranscriptionModel(model.id)
            } else if selectsOnDownload {
                appState.installLocalAIModel(model, autoSelectFor: feature)
            } else {
                appState.installLocalAIModel(model)
            }
        }
        .font(.caption)
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var cancellingView: some View {
        Text(state.progress.localizedDisplayText())
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var progressView: some View {
        HStack(spacing: 8) {
            Text(state.progress.localizedDisplayText())
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 104, alignment: .trailing)

            ZStack {
                if let fraction = state.progress.fractionCompleted {
                    DonutProgressView(fractionCompleted: fraction)
                        .opacity((isHoveringProgress || isCancelFocused) ? 0.25 : 1)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .opacity((isHoveringProgress || isCancelFocused) ? 0.25 : 1)
                }
                Button {
                    appState.cancelLocalAIInstall(model)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .focused($isCancelFocused)
                .opacity((isHoveringProgress || isCancelFocused) ? 1 : 0.001)
                .accessibilityLabel("Cancel Local AI model download")
            }
            .frame(width: 24, height: 24)
            .contentShape(Circle())
            .onHover { isHoveringProgress = $0 }
        }
    }
}

/// A downloadable model's name with its size beside it, a one-sentence
/// description, and the features it supports as tags. Every model row in
/// Settings uses it.
struct ModelRowDescription: View {
    let name: String
    let approximateBytes: Int64
    let description: String
    let featureNames: [String]
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: name)
                    .font(.caption.weight(isSelected ? .semibold : .regular))
                Text(
                    ByteCountFormatter.string(
                        fromByteCount: approximateBytes,
                        countStyle: .file
                    )
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Text(description)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 4) {
                ForEach(featureNames, id: \.self) { name in
                    // The capsule the "+N" notice pill uses.
                    Text(name)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                }
            }
        }
    }
}
