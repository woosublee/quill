import SwiftUI
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    var setupWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private lazy var settingsWindowDelegate = SettingsWindowDelegate(appState: appState)
    private var noteBrowserWindow: NSWindow?
    private var mcpServer: MCPServer?
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

    func updateActivationPolicy() {
        let hasVisibleWindow = setupWindow != nil || settingsWindow != nil || noteBrowserWindow != nil
        if hasVisibleWindow || appState.noteBrowserEnabled {
            NSApp.setActivationPolicy(.regular)
        } else {
            NSApp.setActivationPolicy(.accessory)
        }
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

        // noteBrowserEnabled 변경 시 독 아이콘 상태 갱신
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateActivationPolicy()
        }

        if !appState.hasCompletedSetup {
            showSetupWindow()
        } else {
            updateActivationPolicy()
            // 노트 브라우저 활성화 시 앱 시작과 함께 자동 오픈
            if appState.noteBrowserEnabled {
                showNoteBrowserWindow()
            }
            appState.startHotkeyMonitoring()
            appState.startAccessibilityPolling()
            Task { @MainActor in
                UpdateManager.shared.startPeriodicChecks()
            }

            if appState.requiresAccessibility, !AXIsProcessTrusted() {
                appState.promptForAccessibilityAccess()
            }

            startMCPServer()
            appState.startCalendarRecordingReminderScheduling()
            appState.startGoogleCalendarHealthCheck()
        }

    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        appState.requestTerminationWhileRecording()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard appState.hasCompletedSetup else { return true }
        if appState.noteBrowserEnabled {
            // 노트 브라우저 활성화 시 독 클릭 = 항상 노트 브라우저 앞으로
            showNoteBrowserWindow()
        } else if !flag {
            // 일반 모드: 창이 없을 때만 설정 오픈
            showSettingsWindow()
        }
        return true
    }

    @MainActor
    @objc func handleShowSetup() {
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

private func showNoteBrowserWindow() {
        NSApp.setActivationPolicy(.regular)

        if let noteBrowserWindow, noteBrowserWindow.isVisible {
            noteBrowserWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        if noteBrowserWindow == nil {
            presentNoteBrowserWindow()
        } else {
            noteBrowserWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func presentNoteBrowserWindow() {
        let view = NoteBrowserView()
            .environmentObject(appState)
            .environmentObject(ObsidianExportManager.shared)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 700),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Quill"
        window.contentView = NSHostingView(rootView: view)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 600, height: 400)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        noteBrowserWindow = window

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.noteBrowserWindow = nil
            self?.updateActivationPolicy()
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
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = AppName.displayName
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.delegate = settingsWindowDelegate
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
            self?.updateActivationPolicy()
        }
    }


    func showSetupWindow() {
        NSApp.setActivationPolicy(.regular)

        let setupView = SetupView(onComplete: { [weak self] in
            self?.completeSetup()
        })
        .environmentObject(appState)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 680),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = AppName.displayName
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.contentView = NSHostingView(rootView: setupView)
        window.minSize = NSSize(width: 520, height: 680)
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
        updateActivationPolicy()
        appState.startHotkeyMonitoring()
        appState.startAccessibilityPolling()
        appState.startCalendarRecordingReminderScheduling()
        appState.startGoogleCalendarHealthCheck()
        Task { @MainActor in
            UpdateManager.shared.startPeriodicChecks()
        }

        if appState.requiresAccessibility, !AXIsProcessTrusted() {
            Task { @MainActor in
                appState.promptForAccessibilityAccess()
            }
        }
    }

    private func startMCPServer() {
        let server = MCPServer(appState: appState)
        appState.onTranscriptionCompleted = { [weak server] transcript, context in
            server?.notifyRecordingCompleted(transcript: transcript, context: context)
        }
        do {
            try server.start()
            mcpServer = server
        } catch {
            print("[MCP] Failed to start server: \(error)")
        }
    }
}

private final class SettingsWindowDelegate: NSObject, NSWindowDelegate {
    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState
    }

    @MainActor
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard appState.isInstallingNativeWhisper else { return true }

        let alert = NSAlert()
        alert.messageText = localizedCatalogString("Local Whisper Download in Progress")
        alert.informativeText = localizedCatalogString(
            "Closing Settings will cancel the model download and remove the partial file."
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: localizedCatalogString("Keep Settings Open"))
        alert.addButton(withTitle: localizedCatalogString("Close and Cancel Download"))
        alert.buttons.last?.hasDestructiveAction = true

        guard alert.runModal() == .alertSecondButtonReturn else { return false }
        appState.cancelNativeWhisperInstallForSettingsClose()
        return true
    }
}
