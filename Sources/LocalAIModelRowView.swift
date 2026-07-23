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

struct LocalAIModelRowView: View {
    @EnvironmentObject var appState: AppState

    let feature: AIProcessingFeature
    let model: LocalAIModel
    let isSelected: Bool

    @State private var showDeleteConfirmation = false
    @State private var isHoveringProgress = false
    @FocusState private var isCancelFocused: Bool

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

            if appState.pendingLocalAIModelID(for: feature) == model.id {
                Text("This model will become active when the download finishes.")
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

    private var modelDescription: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: model.displayName)
                .font(.caption.weight(isSelected ? .semibold : .regular))
            Text(
                localizedCatalogFormat(
                    "%@. About %@.",
                    model.localizedDescription(),
                    ByteCountFormatter.string(
                        fromByteCount: model.approximateBytes,
                        countStyle: .file
                    )
                )
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var actionView: some View {
        if state.isInstalling, state.progress.isCancelled {
            cancellingView
        } else if state.isInstalling {
            progressView
        } else if state.progress.isCancelled {
            downloadButton
        } else if state.status == .ready {
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
        } else {
            downloadButton
        }
    }

    private var downloadButton: some View {
        Button("Download") {
            appState.installLocalAIModel(model, autoSelectFor: feature)
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
