import AppKit
import Foundation

struct AppStateStorageLayout: Sendable {
    let rootDirectory: URL

    var audioDirectory: URL {
        rootDirectory.appendingPathComponent("audio", isDirectory: true)
    }

    var transcriptDirectory: URL {
        rootDirectory.appendingPathComponent("transcripts", isDirectory: true)
    }

    var historyStoreURL: URL {
        rootDirectory.appendingPathComponent("PipelineHistory.sqlite")
    }

    /// iCloud sync's engine state and the payload files waiting to upload.
    var noteSyncDirectory: URL {
        rootDirectory.appendingPathComponent("Sync", isDirectory: true)
    }

    var cloudTranscriptionJobsDirectory: URL {
        rootDirectory.appendingPathComponent(
            "cloud-transcription/jobs",
            isDirectory: true
        )
    }

    var cloudTranscriptionTemporaryDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                Bundle.main.bundleIdentifier ?? "com.woosublee.quill",
                isDirectory: true
            )
            .appendingPathComponent("cloud-transcription", isDirectory: true)
    }

    static var live: AppStateStorageLayout {
        AppStateStorageLayout(rootDirectory: AppName.applicationSupportDirectory)
    }
}

struct AppStateLocalAIDependencies {
    typealias InstallStarter = (
        LocalAIModel,
        @escaping (LocalAIDownloadProgress) -> Void,
        @escaping (Result<Void, LocalAIInstallerError>) -> Void
    ) -> LocalAIInstallTask

    var makeServerManager: () -> LocalAIServerManager
    var idleShutdownSleep: @Sendable (UInt64) async throws -> Void
    var installStatus: @Sendable (LocalAIModel) -> LocalAIInstallStatus
    var startInstall: InstallStarter
    var progressSchedule:
        LatestValueProgressCoalescer<LocalAIDownloadProgress>.Schedule
    var deleteModel: @Sendable (LocalAIModel) throws -> Void
    var deletePartialModel: @Sendable (LocalAIModel) throws -> Void
    var processingAvailability: () -> LocalAIProcessingAvailability

    static var live: AppStateLocalAIDependencies {
        let store = LocalAIModelStore()
        return AppStateLocalAIDependencies(
            makeServerManager: { LocalAIServerManager(store: store) },
            idleShutdownSleep: { try await Task.sleep(nanoseconds: $0) },
            installStatus: { store.installStatus(for: $0) },
            startInstall: { model, progress, completion in
                LocalAIInstaller(store: store).install(
                    model: model,
                    progress: progress,
                    completion: completion
                )
            },
            progressSchedule:
                LatestValueProgressCoalescer<LocalAIDownloadProgress>
                    .mainQueueSchedule,
            deleteModel: { try store.deleteModel($0) },
            deletePartialModel: { try store.deletePartialModel($0) },
            processingAvailability: { .live() }
        )
    }
}

struct AppStateNativeWhisperDependencies {
    typealias InstallStarter = (
        NativeWhisperModel,
        @escaping (NativeWhisperDownloadProgress) -> Void,
        @escaping (Result<Void, NativeWhisperInstallerError>) -> Void
    ) -> NativeWhisperInstallTask

    var installStatus:
        @Sendable (NativeWhisperModel) -> NativeWhisperInstallStatus
    var startInstall: InstallStarter
    var progressSchedule:
        LatestValueProgressCoalescer<NativeWhisperDownloadProgress>.Schedule
    var deleteModel: @Sendable (NativeWhisperModel) throws -> Void
    var makeExecutionSnapshot:
        @Sendable () -> NativeWhisperExecutionSnapshot

    static var live: AppStateNativeWhisperDependencies {
        let store = NativeWhisperModelStore()
        return AppStateNativeWhisperDependencies(
            installStatus: { store.installStatus(for: $0) },
            startInstall: { model, progress, completion in
                NativeWhisperInstaller(store: store).install(
                    model: model,
                    progress: progress,
                    completion: completion
                )
            },
            progressSchedule:
                LatestValueProgressCoalescer<NativeWhisperDownloadProgress>
                    .mainQueueSchedule,
            deleteModel: { try store.deleteModel($0) },
            makeExecutionSnapshot: {
                .live(store: store)
            }
        )
    }
}

struct AppStateDependencies {
    var storageLayout: AppStateStorageLayout
    var credentialStorageLayout: CredentialStorageLayout
    var localAI: AppStateLocalAIDependencies
    var nativeWhisper: AppStateNativeWhisperDependencies
    var makePipelineHistoryStore:
        @Sendable (URL) -> PipelineHistoryStore
    var makeMeetingSummaryGenerator:
        @MainActor (MeetingSummaryGeneratorConfiguration)
            -> any MeetingSummaryGenerating
    var makeRetryCloudTranscriptionDependencies:
        @Sendable () -> CloudTranscriptionDependencies
    var makeNoteSyncController:
        @MainActor (AppStateStorageLayout) -> NoteSyncController
    /// Where dictation and retry results are copied for pasting.
    var pasteboard: NSPasteboard
    /// Whether Paste and Return are sent as key presses to the front app.
    var postsKeyEvents: Bool

    /// Test builds copy to a pasteboard of their own and send no key
    /// presses, so running the tests never replaces what the user copied
    /// or pastes into the app in front. The pasteboard is per process, so
    /// runs in other worktrees don't share it; the runner releases it.
    #if QUILL_GROUPED_TEST_RUNNER
    static let testPasteboardNamePrefix = "com.woosublee.quill.tests."
    static let livePasteboard = NSPasteboard(
        name: NSPasteboard.Name(testPasteboardNamePrefix + String(ProcessInfo.processInfo.processIdentifier))
    )
    static let livePostsKeyEvents = false
    #else
    static let livePasteboard = NSPasteboard.general
    static let livePostsKeyEvents = true
    #endif

    static var live: AppStateDependencies {
        AppStateDependencies(
            storageLayout: .live,
            credentialStorageLayout: .live,
            localAI: .live,
            nativeWhisper: .live,
            makePipelineHistoryStore: { PipelineHistoryStore(storeURL: $0) },
            makeMeetingSummaryGenerator: { configuration in
                MeetingSummaryService(
                    backendExecutor: configuration.backendExecutor,
                    cloudFallbackModelID: configuration.cloudFallbackModelID
                )
            },
            makeRetryCloudTranscriptionDependencies: { .live },
            makeNoteSyncController: { layout in
                let stateURL = layout.noteSyncDirectory.appendingPathComponent("engine-state")
                let outbox = layout.noteSyncDirectory.appendingPathComponent("outbox", isDirectory: true)
                let failedChangesURL = layout.noteSyncDirectory.appendingPathComponent("failed-changes.json")
                return NoteSyncController(createZone: {
                    guard #available(macOS 14.0, *) else { return }
                    try await NoteSyncCloudKitEngine.createZone()
                }, deleteLeftoverAudio: {
                    guard #available(macOS 14.0, *) else { return .inUse }
                    return await NoteSyncCloudKitEngine.deleteLeftoverAudio()
                }, deleteAllWithoutEngine: {
                    guard #available(macOS 14.0, *) else { throw NoteSyncEngineError.notRunning }
                    return try await NoteSyncCloudKitEngine.deleteAllWithoutEngine()
                }, removeEngineFiles: {
                    try? FileManager.default.removeItem(at: stateURL)
                    NoteSyncCloudRecord.removeAllOutboxFiles(in: outbox)
                    NoteAudioDownloader.removeDownloadFiles(
                        in: layout.noteSyncDirectory.appendingPathComponent("downloads", isDirectory: true)
                    )
                }, loadFailedChanges: {
                    guard let data = try? Data(contentsOf: failedChangesURL) else { return nil }
                    guard let changes = try? JSONDecoder().decode(NoteSyncFailedChanges.self, from: data) else {
                        print("[NoteSync] Couldn't read the failed changes kept from the last run")
                        try? FileManager.default.removeItem(at: failedChangesURL)
                        return nil
                    }
                    return changes
                }, saveFailedChanges: { changes in
                    do {
                        guard let changes else {
                            if FileManager.default.fileExists(atPath: failedChangesURL.path) {
                                try FileManager.default.removeItem(at: failedChangesURL)
                            }
                            return true
                        }
                        try FileManager.default.createDirectory(at: layout.noteSyncDirectory, withIntermediateDirectories: true)
                        try JSONEncoder().encode(changes).write(to: failedChangesURL, options: .atomic)
                        return true
                    } catch {
                        print("[NoteSync] Couldn't keep the failed changes for the next run")
                        return false
                    }
                }, accountID: {
                    guard #available(macOS 14.0, *) else { return nil }
                    return await NoteSyncCloudKitEngine.accountID()
                }, localAudioURL: { fileName in
                    guard let url = NoteAssetStore(storageLayout: layout).storedAudioURL(fileName: fileName),
                          FileManager.default.fileExists(atPath: url.path) else { return nil }
                    return url
                }, makeEngine: { events in
                    guard #available(macOS 14.0, *) else { return nil }
                    return NoteSyncCloudKitEngine(
                        stateURL: stateURL,
                        outbox: outbox,
                        events: events
                    )
                })
            },
            pasteboard: livePasteboard,
            postsKeyEvents: livePostsKeyEvents
        )
    }
}
