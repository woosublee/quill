import AppKit
import Combine
import Foundation
import Sparkle

// MARK: - Update Status

enum UpdateStatus: Equatable {
    case idle
    case downloading
    case installing
    case readyToRelaunch
    case error(String)
}

// MARK: - Update Manager

@MainActor
final class UpdateManager: NSObject, ObservableObject {
    static let shared = UpdateManager()

    @Published var updateAvailable = false
    @Published var latestReleaseVersion: String = ""
    @Published var latestReleaseDate: String = ""
    @Published var isChecking = false
    @Published var downloadProgress: Double?
    @Published var updateStatus: UpdateStatus = .idle
    @Published var lastCheckDate: Date? {
        didSet {
            if let date = lastCheckDate {
                UserDefaults.standard.set(date, forKey: "updateLastCheckDate")
            }
        }
    }

    var autoCheckEnabled: Bool {
        get { updaterController.updater.automaticallyChecksForUpdates }
        set {
            updaterController.updater.automaticallyChecksForUpdates = newValue
            UserDefaults.standard.set(newValue, forKey: legacyAutoCheckPreferenceKey)
            objectWillChange.send()
        }
    }

    private lazy var updaterController: SPUStandardUpdaterController = {
        SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
    }()

    private let legacyAutoCheckPreferenceKey = "updateAutoCheckEnabled"
    private let legacyAutoCheckMigrationKey = "sparkleAutoCheckPreferenceMigrated"
    private let postTranscriptionReminderInterval: TimeInterval = 24 * 60 * 60 // 1 day
    private var lastPostTranscriptionReminderVersion: String? {
        get { UserDefaults.standard.string(forKey: "updateLastPostTranscriptionReminderVersion") }
        set { UserDefaults.standard.set(newValue, forKey: "updateLastPostTranscriptionReminderVersion") }
    }
    private var lastPostTranscriptionReminderDate: Date? {
        get { UserDefaults.standard.object(forKey: "updateLastPostTranscriptionReminderDate") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "updateLastPostTranscriptionReminderDate") }
    }
    private var releaseNotesURL: URL?
    private var hasStartedUpdater = false
    private var updaterObservationCancellables: Set<AnyCancellable> = []

    private override init() {
        lastCheckDate = UserDefaults.standard.object(forKey: "updateLastCheckDate") as? Date
        super.init()
        migrateLegacyAutoCheckPreferenceIfNeeded()
        bridgeUpdaterChangesToSwiftUI()
    }

    nonisolated static func isReleaseBuildTagForAutomaticChecks(_ buildTag: String?) -> Bool {
        guard let buildTag = buildTag?.trimmingCharacters(in: .whitespacesAndNewlines),
              buildTag.hasPrefix("v") || buildTag.hasPrefix("V") else {
            return false
        }

        var normalized = buildTag
        normalized.removeFirst()

        let versionAndBuildMetadata = normalized
            .split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
        guard let versionPart = versionAndBuildMetadata.first,
              !versionPart.isEmpty else {
            return false
        }

        if versionAndBuildMetadata.count > 1 {
            let buildMetadata = versionAndBuildMetadata[1]
            let identifiers = buildMetadata.split(separator: ".", omittingEmptySubsequences: false)
            guard !buildMetadata.isEmpty,
                  !identifiers.isEmpty,
                  identifiers.allSatisfy({ !$0.isEmpty }) else {
                return false
            }
        }

        let versionAndPrerelease = versionPart
            .split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            .map(String.init)
        guard !versionAndPrerelease.isEmpty else { return false }

        let coreComponents = versionAndPrerelease[0]
            .split(separator: ".", omittingEmptySubsequences: false)
            .map(String.init)
        guard coreComponents.count == 3,
              coreComponents.allSatisfy({ !$0.isEmpty && Int($0) != nil }) else {
            return false
        }

        if versionAndPrerelease.count > 1 {
            let prerelease = versionAndPrerelease[1]
            guard !prerelease.isEmpty else { return false }
            let identifiers = prerelease.split(separator: ".", omittingEmptySubsequences: false)
            guard !identifiers.isEmpty,
                  identifiers.allSatisfy({ !$0.isEmpty }) else {
                return false
            }
        }

        return true
    }

    // MARK: - Sparkle Lifecycle

    func startPeriodicChecks() {
        guard Self.isReleaseBuildTagForAutomaticChecks(currentBuildTag) else { return }
        startUpdaterIfNeeded()
    }

    @MainActor
    func checkForUpdates(userInitiated: Bool) async {
        if !Self.isReleaseBuildTagForAutomaticChecks(currentBuildTag) {
            if userInitiated {
                showReleaseBuildRequiredAlert()
            }
            return
        }

        startUpdaterIfNeeded()
        guard updaterController.updater.canCheckForUpdates else { return }

        isChecking = true
        if userInitiated {
            updaterController.checkForUpdates(nil)
        }
    }

    func showUpdateAlert() {
        Task { @MainActor in
            await checkForUpdates(userInitiated: true)
        }
    }

    func showReleaseNotes() {
        if let releaseNotesURL {
            NSWorkspace.shared.open(releaseNotesURL)
        } else {
            showUpdateAlert()
        }
    }

    func showUpToDateAlert() {
        let alert = NSAlert()
        alert.messageText = "You're Up to Date"
        alert.informativeText = "You're running the latest version of Quill."
        alert.alertStyle = .informational
        alert.icon = NSApp.applicationIconImage
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func cancelDownload() {
        downloadProgress = nil
        updateStatus = .idle
    }

    // MARK: - Post-transcription Reminder

    func shouldShowPostTranscriptionReminder() -> Bool {
        guard updateAvailable,
              updateStatus == .idle,
              !latestReleaseVersion.isEmpty else {
            return false
        }

        guard lastPostTranscriptionReminderVersion == latestReleaseVersion,
              let lastReminder = lastPostTranscriptionReminderDate else {
            return true
        }

        return Date().timeIntervalSince(lastReminder) > postTranscriptionReminderInterval
    }

    func markPostTranscriptionReminderShown() {
        guard !latestReleaseVersion.isEmpty else { return }
        lastPostTranscriptionReminderVersion = latestReleaseVersion
        lastPostTranscriptionReminderDate = Date()
    }

    // MARK: - Private Helpers

    private var currentBuildTag: String? {
        Bundle.main.object(forInfoDictionaryKey: "QuillBuildTag") as? String
    }

    private func startUpdaterIfNeeded() {
        guard !hasStartedUpdater else { return }
        updaterController.startUpdater()
        hasStartedUpdater = true
    }

    private func migrateLegacyAutoCheckPreferenceIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: legacyAutoCheckMigrationKey) else { return }
        if let legacyValue = UserDefaults.standard.object(forKey: legacyAutoCheckPreferenceKey) as? Bool {
            updaterController.updater.automaticallyChecksForUpdates = legacyValue
        }
        UserDefaults.standard.set(true, forKey: legacyAutoCheckMigrationKey)
    }

    private func bridgeUpdaterChangesToSwiftUI() {
        updaterController.updater.publisher(for: \.canCheckForUpdates)
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &updaterObservationCancellables)

        updaterController.updater.publisher(for: \.automaticallyChecksForUpdates)
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &updaterObservationCancellables)
    }

    private func applyAvailableUpdate(_ item: SUAppcastItem) {
        updateAvailable = true
        latestReleaseVersion = item.displayVersionString
        latestReleaseDate = item.date?.formatted(date: .abbreviated, time: .omitted) ?? ""
        releaseNotesURL = item.releaseNotesURL ?? item.infoURL
        updateStatus = .idle
    }

    private func clearAvailableUpdate() {
        updateAvailable = false
        latestReleaseVersion = ""
        latestReleaseDate = ""
        releaseNotesURL = nil
        downloadProgress = nil
        updateStatus = .idle
    }

    private func suppressPostTranscriptionReminder(for item: SUAppcastItem) {
        lastPostTranscriptionReminderVersion = item.displayVersionString
        lastPostTranscriptionReminderDate = Date()
    }

    private func showReleaseBuildRequiredAlert() {
        let alert = NSAlert()
        alert.messageText = "Updates Are Available in Release Builds"
        alert.informativeText = "This local build of Quill does not use automatic updates. Download the latest release from GitHub when you want to update."
        alert.alertStyle = .informational
        alert.icon = NSApp.applicationIconImage
        alert.addButton(withTitle: "Open Releases")
        alert.addButton(withTitle: "OK")

        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "https://github.com/woosublee/quill/releases/latest") {
            NSWorkspace.shared.open(url)
        }
    }
}

extension UpdateManager: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        applyAvailableUpdate(item)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        clearAvailableUpdate()
    }

    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate updateItem: SUAppcastItem, state: SPUUserUpdateState) {
        switch choice {
        case .dismiss, .skip:
            suppressPostTranscriptionReminder(for: updateItem)
        case .install:
            break
        @unknown default:
            break
        }
    }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        applyAvailableUpdate(item)
        updateStatus = .downloading
        downloadProgress = nil
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        applyAvailableUpdate(item)
        updateStatus = .installing
    }

    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) {
        applyAvailableUpdate(item)
        updateStatus = .error("Download failed: \(error.localizedDescription)")
    }

    func userDidCancelDownload(_ updater: SPUUpdater) {
        updateStatus = .idle
        downloadProgress = nil
    }

    func updater(_ updater: SPUUpdater, willExtractUpdate item: SUAppcastItem) {
        applyAvailableUpdate(item)
        updateStatus = .installing
    }

    func updater(_ updater: SPUUpdater, didExtractUpdate item: SUAppcastItem) {
        applyAvailableUpdate(item)
        updateStatus = .installing
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        applyAvailableUpdate(item)
        updateStatus = .readyToRelaunch
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        updateStatus = .readyToRelaunch
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        updateStatus = .error(error.localizedDescription)
        isChecking = false
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        lastCheckDate = Date()
        isChecking = false
        if let error {
            let nsError = error as NSError
            if nsError.domain == SUSparkleErrorDomain, nsError.code == SUError.noUpdateError.rawValue {
                clearAvailableUpdate()
            } else if updateStatus == .idle {
                updateStatus = .error(error.localizedDescription)
            }
        }
    }
}
