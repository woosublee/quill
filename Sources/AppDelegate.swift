import SwiftUI
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    var setupWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var noteBrowserWindow: NSWindow?
    private var mcpServer: MCPServer?

    private func patchSettingsMenuItem() {
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu else { return }
        if let item = appMenu.items.first(where: {
            $0.title.contains("Settings") || $0.title.contains("Preferences")
        }) {
            item.keyEquivalent = ","
            item.keyEquivalentModifierMask = .command
            item.target = self
            item.action = #selector(handleShowSettings)
        } else {
            let item = NSMenuItem(
                title: "Settings...",
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

    func updateActivationPolicy() {
        let hasVisibleWindow = setupWindow != nil || settingsWindow != nil || noteBrowserWindow != nil
        if hasVisibleWindow || appState.noteBrowserEnabled {
            NSApp.setActivationPolicy(.regular)
        } else {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        ObsidianExportManager.shared.requestNotificationPermission()

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
            // Quill releases are not distributed through the in-app updater yet.
            // Task { @MainActor in
            //     UpdateManager.shared.startPeriodicChecks()
            // }

            if !AXIsProcessTrusted() {
                appState.showAccessibilityAlert()
            }

            startMCPServer()
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

    @objc func handleShowSetup() {
        appState.hasCompletedSetup = false
        appState.stopAccessibilityPolling()
        appState.stopHotkeyMonitoring()
        showSetupWindow()
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

    func completeSetup() {
        appState.hasCompletedSetup = true
        setupWindow?.close()
        setupWindow = nil
        updateActivationPolicy()
        appState.startHotkeyMonitoring()
        appState.startAccessibilityPolling()
        // Quill releases are not distributed through the in-app updater yet.
        // Task { @MainActor in
        //     UpdateManager.shared.startPeriodicChecks()
        // }

        if !AXIsProcessTrusted() {
            Task { @MainActor in
                appState.showAccessibilityAlert()
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
