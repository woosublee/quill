import AppKit
import Combine
import Foundation
import Sparkle

// MARK: - Update Status

enum UpdateStatus: Equatable {
    case idle
    case downloading
    case installing
    /// Downloaded in the background and waiting to install. Sparkle installs
    /// it when Quill quits; the user can also restart to install it now.
    case readyToInstall
    case readyToRelaunch
    case error(String)
}

// MARK: - Install Handoff

/// Sparkle's install-on-quit handoff, kept apart from Sparkle so its rules can
/// be tested without a real updater. With automatic installation on, Sparkle
/// downloads and verifies an update, then offers a handler that installs it
/// and relaunches. Quill keeps that handler until it runs or the update cycle
/// ends in failure.
struct UpdateInstallHandoff {
    /// Answer to Sparkle's `willInstallUpdateOnQuit`: Quill takes control so it
    /// can offer Restart to Update. Sparkle still installs on quit, and pauses
    /// new checks until then.
    static let takesControlOfInstallOnQuit = true

    private var install: (() -> Void)?

    var isPending: Bool { install != nil }

    mutating func receive(_ handler: @escaping () -> Void) {
        install = handler
    }

    /// Starts the install. Returns false when nothing is pending. The handler
    /// stays, because Sparkle allows it again after a canceled quit (for
    /// example during a recording).
    @discardableResult
    func installNow() -> Bool {
        guard let install else { return false }
        install()
        return true
    }

    /// Drops the handler when the update cycle ends in failure, so later
    /// checks start a fresh cycle instead of calling a finished one.
    mutating func clear() {
        install = nil
    }
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
    private let sparkleSkippedVersionKey = "SUSkippedVersion"
    private let sparkleSkippedMajorVersionKey = "SUSkippedMajorVersion"
    private let sparkleSkippedMajorSubreleaseVersionKey = "SUSkippedMajorSubreleaseVersion"
    private let updateSnapshotStore = UpdateSnapshotStore(userDefaults: .standard)
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
    private var installHandoff = UpdateInstallHandoff()
    private var hasStartedUpdater = false
    private var updaterObservationCancellables: Set<AnyCancellable> = []

    private override init() {
        lastCheckDate = UserDefaults.standard.object(forKey: "updateLastCheckDate") as? Date
        super.init()
        restorePersistedUpdateIfAvailable()
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

    nonisolated static func isCandidateBuildNewerForRestoration(
        _ candidate: String,
        than current: String
    ) -> Bool {
        SUStandardVersionComparator.default.compareVersion(
            candidate,
            toVersion: current
        ) == .orderedDescending
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

        // While a downloaded update waits (Sparkle pauses new checks until
        // it installs), a manual check installs it instead of doing nothing.
        if userInitiated, hasPendingInstall {
            installReadyUpdateNow()
            return
        }

        startUpdaterIfNeeded()
        guard updaterController.updater.canCheckForUpdates else { return }

        if userInitiated {
            isChecking = true
            updaterController.checkForUpdates(nil)
        }
    }

    func showUpdateAlert() {
        Task { @MainActor in
            await checkForUpdates(userInitiated: true)
        }
    }

    /// True while Sparkle holds a downloaded, verified update for Quill to
    /// install; Sparkle runs no new checks until it installs.
    var hasPendingInstall: Bool { installHandoff.isPending }

    /// False when the update has no release notes or info link; then "What's
    /// New" is hidden rather than falling back to a check.
    var hasReleaseNotes: Bool { releaseNotesURL != nil }

    /// Installs the update Sparkle already downloaded and verified, then
    /// relaunches. The status changes only when Sparkle actually relaunches
    /// (`updaterWillRelaunchApplication`), so canceling the quit prompt (for
    /// example during a recording) keeps Restart to Update available; the
    /// handler can be called again. With nothing pending, this runs a normal
    /// manual check.
    func installReadyUpdateNow() {
        if !installHandoff.installNow() {
            showUpdateAlert()
        }
    }

    func showReleaseNotes() {
        if let releaseNotesURL {
            NSWorkspace.shared.open(releaseNotesURL)
        } else if !hasPendingInstall {
            // Without notes, fall back to a check, but never to installing
            // a waiting update from a "What's New" click.
            showUpdateAlert()
        }
    }


    func showUpToDateAlert() {
        let alert = NSAlert()
        alert.messageText = localizedCatalogString("You're Up to Date")
        alert.informativeText = localizedCatalogString("You're running the latest version of Quill.")
        alert.alertStyle = .informational
        alert.icon = NSApp.applicationIconImage
        alert.addButton(withTitle: localizedCatalogString("OK"))
        alert.runModal()
    }

    func cancelDownload() {
        downloadProgress = nil
        updateStatus = .idle
    }

    // MARK: - Post-transcription Reminder

    func shouldShowPostTranscriptionReminder() -> Bool {
        guard updateAvailable,
              updateStatus == .idle || updateStatus == .readyToInstall,
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

    private var currentBuildVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
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

    private func restorePersistedUpdateIfAvailable() {
        guard Self.isReleaseBuildTagForAutomaticChecks(currentBuildTag) else { return }
        let snapshot = updateSnapshotStore.restorableSnapshot(
            currentBuildVersion: currentBuildVersion,
            skippedUpdate: PersistedSkippedUpdate(
                minorVersion: UserDefaults.standard.string(forKey: sparkleSkippedVersionKey),
                majorVersion: UserDefaults.standard.string(forKey: sparkleSkippedMajorVersionKey),
                majorSubreleaseVersion: UserDefaults.standard.string(
                    forKey: sparkleSkippedMajorSubreleaseVersionKey
                )
            ),
            isNewer: Self.isCandidateBuildNewerForRestoration
        )
        guard let snapshot else { return }
        applyAvailableUpdate(snapshot)
    }

    private func applyAvailableUpdate(_ snapshot: PersistedUpdateSnapshot) {
        updateAvailable = true
        latestReleaseVersion = snapshot.displayVersion
        latestReleaseDate = snapshot.releaseDate?.formatted(date: .abbreviated, time: .omitted) ?? ""
        releaseNotesURL = snapshot.releaseNotesURL
        updateStatus = .idle
    }

    private func applyAvailableUpdate(_ item: SUAppcastItem) {
        let snapshot = PersistedUpdateSnapshot(
            buildVersion: item.versionString,
            displayVersion: item.displayVersionString,
            releaseDate: item.date,
            releaseNotesURL: item.releaseNotesURL ?? item.infoURL,
            minimumAutoupdateVersion: item.minimumAutoupdateVersion,
            ignoreSkippedUpgradesBelowVersion: item.ignoreSkippedUpgradesBelowVersion
        )
        applyAvailableUpdate(snapshot)
        updateSnapshotStore.save(snapshot)
    }

    private func clearAvailableUpdate() {
        updateAvailable = false
        latestReleaseVersion = ""
        latestReleaseDate = ""
        releaseNotesURL = nil
        downloadProgress = nil
        updateStatus = .idle
        updateSnapshotStore.clear()
    }

    private func suppressPostTranscriptionReminder(for item: SUAppcastItem) {
        lastPostTranscriptionReminderVersion = item.displayVersionString
        lastPostTranscriptionReminderDate = Date()
    }

    private func showReleaseBuildRequiredAlert() {
        let alert = NSAlert()
        alert.messageText = localizedCatalogString("Updates Are Available in Release Builds")
        alert.informativeText = localizedCatalogString("This local build of Quill does not use automatic updates. Download the latest release from GitHub when you want to update.")
        alert.alertStyle = .informational
        alert.icon = NSApp.applicationIconImage
        alert.addButton(withTitle: localizedCatalogString("Open Releases"))
        alert.addButton(withTitle: localizedCatalogString("OK"))

        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "https://github.com/woosublee/quill/releases/latest") {
            NSWorkspace.shared.open(url)
        }
    }
}

extension UpdateManager: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        applyAvailableUpdate(item)
        lastCheckDate = Date()
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        clearAvailableUpdate()
    }

    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate updateItem: SUAppcastItem, state: SPUUserUpdateState) {
        switch choice {
        case .dismiss:
            suppressPostTranscriptionReminder(for: updateItem)
        case .skip:
            suppressPostTranscriptionReminder(for: updateItem)
            clearAvailableUpdate()
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
        updateStatus = .error(LocalizedUserMessage.providerFailure(prefix: localizedCatalogString("Download failed"), providerDetail: error.localizedDescription))
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

    /// With automatic installation on, Sparkle downloads in the background and
    /// waits to install until Quill quits. A menu-bar app rarely quits, so
    /// without this the status stayed "Preparing update..." forever. Take the
    /// handoff and offer Restart to Update; Sparkle still installs on quit.
    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        applyAvailableUpdate(item)
        installHandoff.receive(immediateInstallHandler)
        updateStatus = .readyToInstall
        isChecking = false
        lastCheckDate = Date()
        return UpdateInstallHandoff.takesControlOfInstallOnQuit
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        updateStatus = .readyToRelaunch
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        installHandoff.clear()
        updateStatus = .error(LocalizedUserMessage.providerFailure(prefix: localizedCatalogString("Update failed"), providerDetail: error.localizedDescription))
        isChecking = false
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        lastCheckDate = Date()
        isChecking = false
        if let error {
            let nsError = error as NSError
            if nsError.domain == SUSparkleErrorDomain, nsError.code == SUError.noUpdateError.rawValue {
                clearAvailableUpdate()
            } else {
                // The cycle ended in failure; a stored handler would point at
                // a finished cycle, so later checks must start fresh.
                installHandoff.clear()
                if updateStatus == .idle || updateStatus == .readyToInstall {
                    updateStatus = .error(LocalizedUserMessage.providerFailure(prefix: localizedCatalogString("Update failed"), providerDetail: error.localizedDescription))
                }
            }
        }
    }
}
