import Combine
import SwiftUI
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    var setupWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var noteBrowserWindow: NSWindow?
    private var mcpServer: MCPServer?
    private var mcpServerSettingObserver: AnyCancellable?
    private var newSettingsWindow: NSWindow?
    private var newSettingsCloseObserver: NSObjectProtocol?
    private var newSettingsModel: ConnectionsChoicesModel?
    /// Set when setup is re-run over the window: setup offers the same
    /// switches, so closing it applies nothing.
    private var closesNewSettingsWithoutApplying = false
    private var shouldRestoreAfterSetupWindowClose = false

    private func patchSettingsMenuItem() {
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu else { return }
        if let item = appMenu.items.first(where: {
            Self.isSettingsMenuItemTitle($0.title, localizedSettingsTitle: String(localized: "Settings..."))
        }) {
            item.keyEquivalent = ","
            item.keyEquivalentModifierMask = .command
            item.target = self
            item.action = #selector(handleShowSettings)
        } else {
            let item = NSMenuItem(
                title: NSLocalizedString("Settings...", comment: "Settings menu action"),
                action: #selector(handleShowSettings),
                keyEquivalent: ","
            )
            item.keyEquivalentModifierMask = .command
            item.target = self
            let insertIndex = min(2, appMenu.items.count)
            appMenu.insertItem(NSMenuItem.separator(), at: insertIndex)
            appMenu.insertItem(item, at: insertIndex + 1)
        }
    }

    static func isSettingsMenuItemTitle(_ title: String, localizedSettingsTitle: String) -> Bool {
        let recognizedTitles = [localizedSettingsTitle, "Settings...", "Settings", "Preferences...", "Preferences"]
        return recognizedTitles.contains(title)
    }

    /// Quill always keeps its Dock icon: the Dock icon opens the note
    /// browser. Info.plist starts the app as an accessory (LSUIElement).
    func updateActivationPolicy() {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NetworkMonitor.shared.start()

        AppNotificationManager.shared.install()
        AppNotificationManager.shared.setCalendarReminderHandler { [weak self] action in
            self?.appState.startRecordingFromCalendarReminder(action)
        }

        // 저장된 appearance 설정 적용
        let savedAppearance = UserDefaults.standard.string(forKey: "app_appearance") ?? "system"
        switch savedAppearance {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark":  NSApp.appearance = NSAppearance(named: .darkAqua)
        default:      NSApp.appearance = nil
        }

        // SwiftUI 메뉴 초기화 이후 Settings 단축키 강제 설정
        DispatchQueue.main.async {
            self.patchSettingsMenuItem()
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShowSetup),
            name: .showSetup,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShowSettings),
            name: .showSettings,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShowNoteBrowser),
            name: .showNoteBrowser,
            object: nil
        )

        appState.startLocalAIIdleShutdownMonitoring()
        appState.startRecentlyDeletedPurgeSchedule()
        appState.startNoteSync()

        if !appState.hasCompletedSetup {
            showSetupWindow()
        } else {
            startPostSetupServices()
            showNewSettingsIfNeeded()
        }

    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let recordingReply = appState.requestTerminationWhileRecording()
        guard recordingReply == .terminateNow else { return recordingReply }
        return appState.requestTerminationAfterModelCleanup()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Quitting with New settings open keeps the AI tools choice; iCloud
        // sync can't start now, so the window comes back if it was chosen.
        if let selection = newSettingsModel?.selection {
            if selection.wantsMCP != selection.mcpWasOn {
                appState.isMCPServerEnabled = selection.wantsMCP
            }
            if !selection.wantsICloudSync {
                UserDefaults.standard.set(true, forKey: ConnectionsChoices.seenStorageKey)
            }
        }
        // Quitting ends the Cancel window of a just-deleted note.
        appState.finalizePendingNoteDeletion()
        appState.stopRecentlyDeletedPurgeSchedule()
        // Pieces of a deleted unrecovered recording are removed in the
        // background; let that finish so the note does not come back.
        appState.waitForPendingRecordingPieceRemovals(timeout: 2)
    }

    /// iCloud sync registers for CloudKit pushes; without them another Mac's
    /// changes mostly wait until Quill comes to the front. Only the error's
    /// domain and code are printed.
    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        let nsError = error as NSError
        print("[NoteSync] Push registration failed: \(nsError.domain) \(nsError.code)")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard appState.hasCompletedSetup else { return true }
        // 독 클릭 = 항상 노트 브라우저 앞으로
        showNoteBrowserWindow()
        return true
    }

    @MainActor
    @objc func handleShowSetup() {
        // Setup offers the same switches, so the New settings window just
        // closes; its choices aren't applied over the wizard.
        if let newSettingsWindow {
            closesNewSettingsWithoutApplying = true
            newSettingsWindow.close()
        }
        // Single wizard at a time — opening a second leaks the first's
        // willClose observer and breaks the bail-restore.
        if let existing = setupWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        if let setupWindow {
            NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: setupWindow)
        }
        shouldRestoreAfterSetupWindowClose = false

        let wasCompleted = appState.hasCompletedSetup
        appState.hasCompletedSetup = false
        appState.stopAccessibilityPolling()
        appState.stopHotkeyMonitoring()
        showSetupWindow()

        // Restore prior state if the user closes the wizard without completing.
        // completeSetup() flips hasCompletedSetup back to true before window.close(),
        // so the !hasCompletedSetup check below correctly skips the restore there.
        if wasCompleted, let window = setupWindow {
            shouldRestoreAfterSetupWindowClose = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleSetupWindowDidClose),
                name: NSWindow.willCloseNotification,
                object: window
            )
        }
    }

    @MainActor
    @objc private func handleSetupWindowDidClose(_ notification: Notification) {
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.willCloseNotification,
            object: notification.object
        )
        let shouldRestore = shouldRestoreAfterSetupWindowClose
        shouldRestoreAfterSetupWindowClose = false
        // A re-run closed early ends here; its choices aren't resumed later.
        SetupFlow.clearSavedProgress(in: .standard)
        if shouldRestore, !appState.hasCompletedSetup {
            appState.hasCompletedSetup = true
            appState.startHotkeyMonitoring()
            appState.startAccessibilityPolling()
        }
        setupWindow = nil
        updateActivationPolicy()
    }

    @objc private func handleShowSettings() {
        showSettingsWindow()
    }

    @objc private func handleShowNoteBrowser() {
        showNoteBrowserWindow()
    }


private func showNoteBrowserWindow() {
        NSApp.setActivationPolicy(.regular)
        MainActor.assumeIsolated { appState.noteSyncController?.fetchSoon() }

        if let noteBrowserWindow, noteBrowserWindow.isVisible {
            noteBrowserWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        if noteBrowserWindow == nil {
            presentNoteBrowserWindow()
        } else if let noteBrowserWindow {
            noteBrowserWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            clearInitialFocus(in: noteBrowserWindow)
        }
    }

    /// Opening the window should not put a focus ring on its first control.
    /// Keyboard focus still moves there with Tab. SwiftUI picks a first
    /// responder after the window appears, so this clears it on the next pass.
    private func clearInitialFocus(in window: NSWindow) {
        DispatchQueue.main.async { [weak window] in
            window?.makeFirstResponder(nil)
        }
    }

    private func presentNoteBrowserWindow() {
        let view = NoteBrowserView()
            .environmentObject(appState)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 700),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // Unified title bar: the traffic lights sit on the sidebar's first row.
        // The title stays set for Mission Control and the Window menu.
        window.title = AppName.displayName
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        // An empty unified toolbar gives the taller title bar, so the traffic
        // lights get the standard inset from the top and left edges.
        window.toolbar = NSToolbar(identifier: "NoteBrowser")
        window.toolbarStyle = .unified
        window.contentView = NSHostingView(rootView: view)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 600, height: 400)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        clearInitialFocus(in: window)

        noteBrowserWindow = window

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.noteBrowserWindow = nil
        }
    }

    private func showSettingsWindow() {
        NSApp.setActivationPolicy(.regular)

        if let settingsWindow, settingsWindow.isVisible {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        if settingsWindow == nil {
            presentSettingsWindow()
        } else {
            settingsWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func presentSettingsWindow() {
        let settingsView = SettingsView()
            .environmentObject(appState)
        let hostingView = NSHostingView(rootView: settingsView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 540),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // Same unified title bar as the Note Browser: no title text or
        // separator, traffic lights on the sidebar's first row. The title
        // stays set for Mission Control and the Window menu.
        window.title = AppName.displayName
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.toolbar = NSToolbar(identifier: "Settings")
        window.toolbarStyle = .unified
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        settingsWindow = window

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.settingsWindow = nil
        }
    }


    func showSetupWindow() {
        NSApp.setActivationPolicy(.regular)

        let setupView = SetupView(onComplete: { [weak self] selection in
            self?.completeSetup()
            self?.applyConnectionsChoices(selection)
        })
        .environmentObject(appState)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 720),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = AppName.displayName
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.contentView = NSHostingView(rootView: setupView)
        window.minSize = NSSize(width: 620, height: 600)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.isReleasedWhenClosed = false

        self.setupWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    func completeSetup() {
        appState.hasCompletedSetup = true
        setupWindow?.close()
        setupWindow = nil
        startPostSetupServices()
    }

    /// Existing users get the new iCloud sync and AI tools switches once,
    /// in a small window of their own; nothing else about setup changes.
    /// Done and the close button both apply what is chosen.
    @MainActor
    private func showNewSettingsIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: ConnectionsChoices.seenStorageKey),
              newSettingsWindow == nil, setupWindow == nil else { return }
        let hadMCPOff = !appState.isMCPServerEnabled
        let model = ConnectionsChoicesModel(
            selection: ConnectionsChoices.Selection(
                wantsMCP: appState.isMCPServerEnabled,
                mcpWasOn: appState.isMCPServerEnabled
            )
        )
        newSettingsModel = model
        let view = NewSettingsView(model: model, showsMCPChangeNote: hadMCPOff, onDone: { [weak self] in
            self?.newSettingsWindow?.close()
        })
        .environmentObject(appState)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 640),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = AppName.displayName
        window.titlebarAppearsTransparent = true
        window.contentView = NSHostingView(rootView: view)
        window.minSize = NSSize(width: 560, height: 520)
        window.isReleasedWhenClosed = false
        window.center()
        newSettingsWindow = window
        newSettingsCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let observer = self.newSettingsCloseObserver {
                    NotificationCenter.default.removeObserver(observer)
                }
                self.newSettingsCloseObserver = nil
                self.newSettingsWindow = nil
                self.newSettingsModel = nil
                if self.closesNewSettingsWithoutApplying {
                    self.closesNewSettingsWithoutApplying = false
                } else {
                    self.applyConnectionsChoices(model.selection)
                }
            }
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Applies the Connections and Sync choices together and marks them
    /// seen. Turning on iCloud sync can fail (signed out, offline); that is
    /// said right away, since the choice isn't offered again.
    @MainActor
    private func applyConnectionsChoices(_ selection: ConnectionsChoices.Selection) {
        UserDefaults.standard.set(true, forKey: ConnectionsChoices.seenStorageKey)
        if selection.wantsMCP != selection.mcpWasOn {
            appState.isMCPServerEnabled = selection.wantsMCP
        }
        guard selection.wantsICloudSync,
              let controller = appState.noteSyncController,
              !controller.isEnabled else { return }
        Task { @MainActor [weak self] in
            if let failure = await controller.turnOn() {
                self?.showICloudSyncTurnOnFailure(failure)
            }
        }
    }

    @MainActor
    private func showICloudSyncTurnOnFailure(_ failure: NoteSyncTurnOnFailure) {
        let reason: String
        switch failure {
        case .signedOut:
            reason = localizedCatalogString("Check your iCloud account in System Settings, then try again.")
        case .notReady:
            reason = localizedCatalogString("Notes can't sync right now. If history recovery is running, try again after it finishes.")
        case .unreachable:
            reason = localizedCatalogString("Check your internet connection and try again. Sync is still off.")
        }
        let alert = NSAlert()
        alert.messageText = localizedCatalogString("Couldn't turn on iCloud sync")
        alert.informativeText = reason + "\n\n" + localizedCatalogString("You can turn it on later in Settings › iCloud Sync.")
        alert.addButton(withTitle: localizedCatalogString("Open Settings"))
        alert.addButton(withTitle: localizedCatalogString("OK"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            appState.selectedSettingsTab = .sync
            showSettingsWindow()
        }
    }

    /// Every service a normal relaunch starts once setup is already
    /// complete. Finishing the setup wizard must start the same set, so
    /// this is the single shared entry point for both.
    @MainActor
    private func startPostSetupServices() {
        updateActivationPolicy()
        // 앱 시작과 함께 노트 브라우저 자동 오픈
        showNoteBrowserWindow()
        appState.startHotkeyMonitoring()
        appState.startAccessibilityPolling()
        Task { @MainActor in
            UpdateManager.shared.startPeriodicChecks()
        }

        if appState.requiresAccessibility, !AXIsProcessTrusted() {
            appState.promptForAccessibilityAccess()
        }

        observeMCPServerSetting()
        appState.startCalendarRecordingReminderScheduling()
        appState.startGoogleCalendarHealthCheck()
    }

    private func startMCPServer() {
        guard mcpServer == nil else { return }
        let server = MCPServer(appState: appState)
        appState.onTranscriptionCompleted = { [weak server] transcript, context in
            server?.notifyRecordingCompleted(transcript: transcript, context: context)
        }
        server.onStatusChange = { [weak self, weak server] status in
            DispatchQueue.main.async {
                // A server already stopped doesn't report any more.
                guard let self, let server, self.mcpServer === server else { return }
                if status == .failed {
                    // Let go of the dead listener, so turning the switch off
                    // and on starts a fresh one.
                    self.stopMCPServer(status: .failed)
                } else {
                    self.appState.mcpServerStatus = status
                }
            }
        }
        appState.mcpServerStatus = .starting
        do {
            try server.start()
            mcpServer = server
        } catch {
            print("[MCP] Failed to start server: \(error)")
            appState.onTranscriptionCompleted = nil
            appState.mcpServerStatus = .failed
        }
    }

    /// Closes port 3457 and drops connected AI tools.
    private func stopMCPServer(status: MCPServerStatus = .off) {
        appState.onTranscriptionCompleted = nil
        // Context a tool added isn't kept for the next tool to read.
        appState.mcpAdditionalContext = ""
        appState.mcpLastRecordingFailed = false
        mcpServer?.stop()
        mcpServer = nil
        appState.mcpServerStatus = status
    }

    /// Settings › AI Tools turns the server on and off; it starts off.
    private func observeMCPServerSetting() {
        guard mcpServerSettingObserver == nil else { return }
        mcpServerSettingObserver = appState.$isMCPServerEnabled
            .removeDuplicates()
            .sink { [weak self] isEnabled in
                if isEnabled {
                    self?.startMCPServer()
                } else {
                    self?.stopMCPServer()
                }
            }
    }
}
