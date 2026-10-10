import SwiftUI

/// The note's audio bar: the player when the audio is on this Mac, and a
/// download bar when it is in iCloud. A finished download swaps in the
/// player, which starts playing when the download was asked to play.
struct NoteAudioBar: View {
    let item: PipelineHistoryItem
    @ObservedObject var downloader: NoteAudioDownloader
    /// Shows a toast, as other note actions do.
    let onMessage: (String) -> Void

    @EnvironmentObject private var appState: AppState
    @State private var playsWhenDownloaded = false

    var body: some View {
        switch appState.noteAudioState(for: item) {
        case .none:
            EmptyView()
        case .local:
            if let url = appState.noteBrowserStoredAudioURL(for: item) {
                NoteAudioPlayerView(audioURL: url, playsOnAppear: playsWhenDownloaded)
            }
        case let state:
            NoteRemoteAudioBarView(
                state: state,
                duration: recordedDuration,
                onDownload: download,
                onCancel: { appState.cancelNoteAudioDownload(for: item) }
            )
        }
    }

    /// From the recording's start and end, since the file isn't here to read.
    private var recordedDuration: TimeInterval? {
        guard let start = item.recordingStartedAt, let end = item.recordingEndedAt, end > start else { return nil }
        return end.timeIntervalSince(start)
    }

    private func download() {
        playsWhenDownloaded = true
        Task { @MainActor in
            guard await appState.downloadNoteAudio(for: item) == nil else { return }
            playsWhenDownloaded = false
            if let message = appState.noteAudioState(for: item).failureToast { onMessage(message) }
        }
    }
}

/// Audio that isn't on this Mac: a download button (a ring with a stop mark
/// while downloading), flat bars, and the recorded length, or in its place a
/// lasting reason it can't be downloaded (the full sentence on hover).
struct NoteRemoteAudioBarView: View {
    let state: NoteAudioState
    let duration: TimeInterval?
    let onDownload: () -> Void
    let onCancel: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var isDownloading: Bool {
        if case .downloading = state { return true }
        return false
    }

    private var toolbarStrokeColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.10) : Color.primary.opacity(0.10)
    }

    var body: some View {
        HStack(spacing: 14) {
                button
                GeometryReader { geo in
                    let layout = AudioWaveformHeights.layout(width: geo.size.width, barCount: 80, preferredGap: 2)
                    HStack(alignment: .center, spacing: layout.gap) {
                        ForEach(0..<layout.barCount, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 1)
                                .fill(Color.primary.opacity(0.18))
                                .frame(width: layout.barWidth, height: geo.size.height * 0.15)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
                .frame(height: 44)
                .accessibilityHidden(true)
                if let status = state.barStatus {
                    Text(status)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .help(state.unavailableMessage ?? status)
                } else if let duration {
                    Text(verbatim: NoteAudioPlayerView.formatDuration(duration))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(height: 72)
            .background {
                RoundedRectangle(cornerRadius: 12)
                    .fill(
                        LinearGradient(
                            colors: [Color.accentColor.opacity(0.06), Color.clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                    }
            }
            .opacity(state.canStartDownload || isDownloading ? 1 : 0.6)
    }

    @ViewBuilder
    private var button: some View {
        Button {
            if isDownloading { onCancel() } else { onDownload() }
        } label: {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.10))
                    .overlay(GlassView(material: .popover).clipShape(Circle()))
                    .overlay(Circle().strokeBorder(toolbarStrokeColor, lineWidth: 0.7))
                    .frame(width: 36, height: 36)
                if case .downloading(let fraction) = state {
                    Circle()
                        .trim(from: 0, to: max(0.02, min(fraction, 1)))
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 30, height: 30)
                    Image(systemName: "stop.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.primary)
                } else {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.primary)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!state.canStartDownload && !isDownloading)
        .help(isDownloading ? "Stop Download" : "Download Audio")
        .accessibilityLabel(Text(isDownloading ? "Stop Download" : "Download Audio"))
        .accessibilityValue(downloadProgressText)
    }

    private var downloadProgressText: Text {
        guard case .downloading(let fraction) = state else { return Text(verbatim: "") }
        return Text(verbatim: "\(Int((fraction * 100).rounded()))%")
    }
}
