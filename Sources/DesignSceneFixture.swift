import AppKit
import Foundation
import QuillAITextCore
import QuillAudioFormatCore
import QuillNoteSyncCore
import QuillUserIssueCore

/// Development-only screenshots of the note window (#697). Active only in a
/// separately built app whose bundle identifier is `bundleIdentifier`, and
/// only when launched with `-QuillDesignScene <name>`. The scene runs on a
/// fresh store in a temporary folder with invented Korean notes; sync,
/// calendar, updates, shortcuts, and model downloads never start, and no
/// key is read from or written to the Keychain.
enum DesignSceneFixture {
    static let bundleIdentifier = "com.woosublee.quill.shots"
    static let browserStateNotification = Notification.Name("QuillDesignSceneBrowserState")

    enum Scene: String, CaseIterable {
        case noRecordings
        case noSelection
        case noSearchResults
        case emptyTranscript
        case nothingToCleanUp
        case postProcessingWarning
        case bothNotices
        case retranscribeCompare
        case toolbar
        case metaLine
    }

    struct BrowserState {
        var clearsSelection = false
        var searchQuery: String?
    }

    static let active: Scene? = {
        guard Bundle.main.bundleIdentifier == bundleIdentifier else { return nil }
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-QuillDesignScene"),
              arguments.indices.contains(index + 1) else { return nil }
        return Scene(rawValue: arguments[index + 1])
    }()

    private static let rootDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("QuillDesignScene-\(UUID().uuidString)", isDirectory: true)
    private static let audioFileName = "design-scene-tone.wav"
    private static var focusedNoteID: UUID?
    private static var candidateTranscript: String?

    /// The live dependencies, or the scene's temporary ones.
    static var appStateDependencies: AppStateDependencies {
        guard let scene = active else { return .live }
        // Registered defaults stay in memory; nothing is written for them.
        UserDefaults.standard.register(defaults: [
            "hasCompletedSetup": true,
            "app_appearance": "light",
            ConnectionsChoices.seenStorageKey: true,
            "transcription_enabled": true
        ])
        let layout = AppStateStorageLayout(rootDirectory: rootDirectory)
        try? FileManager.default.createDirectory(at: layout.audioDirectory, withIntermediateDirectories: true)
        seed(scene, layout: layout)
        var dependencies = AppStateDependencies.live
        dependencies.storageLayout = layout
        dependencies.credentialStorageLayout = CredentialStorageLayout(
            directory: rootDirectory,
            secrets: UnavailableCredentialSecretStore()
        )
        return dependencies
    }

    /// Opens the scene's note, and its comparison, search, or empty
    /// selection, once the window shows the loaded list.
    @MainActor
    static func present(_ scene: Scene, in appState: AppState) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            MainActor.assumeIsolated {
                appState.applyDesignScene(transcriptionCandidate: candidateTranscript, noteID: focusedNoteID)
                if let id = focusedNoteID {
                    appState.openNoteInBrowser(id: id)
                }
                var state = BrowserState()
                switch scene {
                case .noSelection: state.clearsSelection = true
                case .noSearchResults: state.searchQuery = "출장 정산"
                default: break
                }
                if state.clearsSelection || state.searchQuery != nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        NotificationCenter.default.post(name: browserStateNotification, object: state)
                    }
                }
            }
        }
    }

    static func removeTemporaryFiles() {
        guard active != nil else { return }
        try? FileManager.default.removeItem(at: rootDirectory)
    }

    // MARK: Synthetic notes

    private static let weeklyTranscript = """
    이번 주에는 노트 화면 정리 작업을 마무리하기로 했어요. 목록 폭은 그대로 두고, 위쪽 도구 막대만 조금 줄이기로 했습니다.

    다음 회의 전까지 시안을 두 가지 준비해 오기로 했고, 색상은 지금 쓰는 토큰을 그대로 쓰기로 했어요. 접근성 대비는 따로 한 번 더 확인하기로 했습니다.
    """

    private static let weeklyRetranscript = """
    이번 주에는 노트 화면 정리 작업을 마무리하기로 했어요. 목록 너비는 그대로 두고, 위쪽 도구 막대만 조금 줄이기로 했습니다.

    다음 회의 전까지 시안 두 가지를 준비해 오기로 했고, 색상은 지금 쓰는 디자인 토큰을 그대로 쓰기로 했어요. 접근성 대비는 따로 한 번 더 확인하기로 했습니다.
    """

    private static let interviewTranscript = """
    오늘 인터뷰에서는 녹음을 시작하는 방법이 가장 많이 나왔어요. 처음 쓰는 분들은 메뉴 막대 아이콘을 잘 찾지 못했고, 단축키를 알려 드리자 바로 익숙해졌습니다.

    요약은 회의가 끝나고 바로 보고 싶다는 의견이 많았어요.
    """

    private static let studyTranscript = """
    스터디 모임은 다음 달부터 격주 목요일 저녁으로 옮기기로 했어요. 장소는 지금처럼 온라인으로 하고, 발표 순서는 이름 가나다순으로 정했습니다.
    """

    private static let lunchTranscript = "점심은 근처 국숫집으로 가기로 했어요. 열두 시 반에 일 층에서 만나요."

    private static func seed(_ scene: Scene, layout: AppStateStorageLayout) {
        guard scene != .noRecordings else { return }
        let store = PipelineHistoryStore(storeURL: layout.historyStoreURL)
        let now = Date()
        var notes: [PipelineHistoryItem] = [
            note(title: "점심 약속", transcript: lunchTranscript, minutesAgo: 60 * 26),
            note(title: "스터디 일정 조율", transcript: studyTranscript, minutesAgo: 60 * 8),
            note(title: "사용자 인터뷰 메모", transcript: interviewTranscript, minutesAgo: 60 * 3)
        ]
        var focused: PipelineHistoryItem?
        switch scene {
        case .noRecordings, .noSelection, .noSearchResults:
            notes.append(note(title: "주간 제품 회의", transcript: weeklyTranscript, minutesAgo: 25, hasAudio: true))
        case .emptyTranscript:
            focused = note(title: "짧은 메모", transcript: "", minutesAgo: 10, hasAudio: true)
        case .nothingToCleanUp:
            focused = note(
                title: "주간 제품 회의",
                transcript: weeklyTranscript,
                minutesAgo: 25,
                hasAudio: true,
                issue: PostProcessingError.emptyOutput.userIssueRecord(providerHost: nil, modelID: "design-scene-model"),
                outcome: .failed(reason: "empty-output")
            )
        case .postProcessingWarning, .bothNotices:
            focused = note(
                title: "주간 제품 회의",
                transcript: weeklyTranscript,
                minutesAgo: 25,
                hasAudio: true,
                issue: PostProcessingError.requestTimedOut(60, modelID: "design-scene-model")
                    .userIssueRecord(providerHost: nil, modelID: "design-scene-model"),
                outcome: .failed(reason: "request-timed-out")
            )
        case .retranscribeCompare:
            focused = note(title: "주간 제품 회의", transcript: weeklyTranscript, minutesAgo: 25, hasAudio: true)
            candidateTranscript = weeklyRetranscript
        case .toolbar:
            focused = note(title: "주간 제품 회의", transcript: weeklyTranscript, minutesAgo: 25, hasAudio: true)
        case .metaLine:
            focused = note(
                title: "주간 제품 회의",
                transcript: weeklyTranscript,
                minutesAgo: 25,
                hasAudio: true,
                local: true,
                context: false,
                language: "ko"
            )
        }
        if let focused { notes.append(focused) }
        if notes.contains(where: { $0.audioFileName != nil }) {
            writeTone(to: layout.audioDirectory.appendingPathComponent(audioFileName))
        }
        for item in notes {
            _ = try? store.append(item, maxCount: Int.max)
        }
        if scene == .bothNotices, let focused {
            try? store.setUnchangedRetranscription(
                .matching(focused.displayedTranscript, at: now),
                id: focused.id
            )
        }
        focusedNoteID = focused?.id
    }

    private static func note(
        title: String,
        transcript: String,
        minutesAgo: Double,
        hasAudio: Bool = false,
        issue: QuillUserIssueRecord? = nil,
        outcome: AIProcessingOutcome = .succeeded,
        local: Bool = false,
        context: Bool = true,
        language: String = "auto"
    ) -> PipelineHistoryItem {
        let end = Date().addingTimeInterval(-minutesAgo * 60)
        let start = end.addingTimeInterval(-12 * 60)
        return PipelineHistoryItem(
            timestamp: end,
            recordingStartedAt: start,
            recordingEndedAt: end,
            rawTranscript: transcript,
            postProcessedTranscript: transcript,
            postProcessingPrompt: nil,
            contextSummary: "",
            contextScreenshotDataURL: nil,
            contextScreenshotStatus: "",
            postProcessingStatus: issue?.persistedStatus
                ?? (transcript.isEmpty
                    ? "Skipped macros and post-processing for empty raw transcript"
                    : "Post-processing succeeded"),
            aiProcessingOutcome: outcome.pipelineHistoryStatus,
            debugStatus: "",
            customVocabulary: "",
            audioFileName: hasAudio ? audioFileName : nil,
            usedLocalTranscription: local,
            usedContextCapture: context,
            usedPostProcessing: true,
            transcriptionLanguageCode: language,
            customTitle: title
        )
    }

    /// Twenty seconds of a quiet, slowly swelling 220 Hz tone, so the
    /// waveform has shape. Generated; never recorded.
    private static func writeTone(to url: URL) {
        let sampleRate = Double(CanonicalPCM16WAV.sampleRate)
        let frameCount = Int(sampleRate * 20)
        var samples = Data(capacity: frameCount * 2)
        for frame in 0..<frameCount {
            let time = Double(frame) / sampleRate
            let envelope = 0.15 + 0.35 * abs(sin(time * 1.3)) * abs(sin(time * 0.37 + 0.5))
            let value = Int16(clamping: Int(sin(2 * .pi * 220 * time) * envelope * Double(Int16.max)))
            withUnsafeBytes(of: value.littleEndian) { samples.append(contentsOf: $0) }
        }
        guard let header = try? CanonicalPCM16WAV.header(dataByteCount: UInt32(samples.count)) else { return }
        try? (header + samples).write(to: url)
    }
}
