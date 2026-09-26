import AppKit
import ApplicationServices
import SwiftUI

/// Opens the System Settings pane for a permission and shows a small panel
/// attached to the Settings window with Quill's icon, which people drag into
/// the permission list. Only Settings and this panel appear: no system
/// permission dialog is shown at the same time.
@MainActor
final class PermissionGuideController {
    private static let panelSize = NSSize(width: 460, height: 104)
    /// 30 Hz keeps the panel attached while the Settings window moves. When
    /// Quill has Accessibility access, window move/resize notifications
    /// update it immediately as well.
    private static let trackingInterval: TimeInterval = 1.0 / 30.0
    /// System Settings can take a moment to launch before its window exists.
    private static let grantedDisplayDuration: TimeInterval = 1.5

    private var panel: NSPanel?
    private var model: PermissionGuideModel?
    private var trackingTimer: Timer?
    private var presentedAt = Date.distantPast
    private var isGranted: (@MainActor () -> Bool)?
    private var onGranted: (@MainActor () -> Void)?
    private var isClosingAfterGrant = false
    /// Identifies the current guide, so a delayed close scheduled by an
    /// earlier guide cannot close a newer one.
    private var presentationID = UUID()
    private var hasSeenSettingsWindow = false
    private var windowMissingSince: Date?
    private var windowObserver: AXObserver?
    private var observedSettingsPID: pid_t?
    /// The app that was in front before Settings opened, such as Quill's
    /// onboarding window; it is brought back once access is granted.
    private var previousApplication: NSRunningApplication?

    var isPresented: Bool { panel != nil }

    func present(
        kind: PermissionGuideKind,
        appName: String,
        appURL: URL,
        isGranted: @escaping @MainActor () -> Bool,
        onGranted: @escaping @MainActor () -> Void
    ) {
        dismiss()
        let model = PermissionGuideModel(
            kind: kind,
            appName: appName,
            dragURL: PermissionGuideLayout.dragURL(for: appURL)
        )
        self.model = model
        self.isGranted = isGranted
        self.onGranted = onGranted
        isClosingAfterGrant = false
        presentationID = UUID()
        hasSeenSettingsWindow = false
        windowMissingSince = nil
        presentedAt = Date()
        let frontmost = NSWorkspace.shared.frontmostApplication
        previousApplication = frontmost?.bundleIdentifier
            == SystemSettingsWindowLocator.bundleIdentifier ? nil : frontmost

        let panel = Self.makePanel()
        panel.contentView = FixedHostingContainer(
            rootView: AnyView(PermissionGuideView(model: model) { [weak self] in
                self?.dismiss()
            }),
            size: Self.panelSize
        )
        self.panel = panel

        NSWorkspace.shared.open(kind.settingsURL)
        let timer = Timer(timeInterval: Self.trackingInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = Self.trackingInterval * 0.25
        // .common keeps tracking while menus or drags run the event loop.
        RunLoop.main.add(timer, forMode: .common)
        trackingTimer = timer
    }

    func dismiss() {
        previousApplication = nil
        closePanel()
    }

    private func closePanel() {
        stopObservingSettingsWindow()
        trackingTimer?.invalidate()
        trackingTimer = nil
        panel?.orderOut(nil)
        panel = nil
        model = nil
        isGranted = nil
        onGranted = nil
    }

    private func tick() {
        guard let panel, let model else { return }
        if !isClosingAfterGrant, isGranted?() == true {
            isClosingAfterGrant = true
            model.isGranted = true
            onGranted?()
            let grantedPresentation = presentationID
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.grantedDisplayDuration) { [weak self] in
                guard let self, self.presentationID == grantedPresentation else { return }
                let previous = self.previousApplication
                self.dismiss()
                previous?.activate()
            }
        }

        let settings = NSRunningApplication.runningApplications(
            withBundleIdentifier: SystemSettingsWindowLocator.bundleIdentifier
        ).first
        let screens = Self.screens()
        var settingsFrame: CGRect?
        if let settings {
            let windowInfo = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
            ) as? [[String: Any]] ?? []
            settingsFrame = SystemSettingsWindowLocator.settingsWindowFrame(
                windowInfo: windowInfo,
                settingsPID: settings.processIdentifier,
                screens: screens
            )
        }
        if let settings {
            observeSettingsWindowIfPossible(pid: settings.processIdentifier)
        }
        let now = Date()
        if settingsFrame != nil {
            hasSeenSettingsWindow = true
            windowMissingSince = nil
        } else if hasSeenSettingsWindow, windowMissingSince == nil {
            windowMissingSince = now
        }

        let action = PermissionGuidePanelAction.decide(
            settingsIsRunning: settings != nil,
            settingsIsFrontmost: NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                == SystemSettingsWindowLocator.bundleIdentifier,
            settingsWindowFrame: settingsFrame,
            hasSeenSettingsWindow: hasSeenSettingsWindow,
            windowMissingFor: windowMissingSince.map { now.timeIntervalSince($0) } ?? 0,
            elapsed: now.timeIntervalSince(presentedAt)
        )
        let frame: NSRect
        switch action {
        case .dismiss:
            dismiss()
            return
        case .hide:
            panel.orderOut(nil)
            return
        case .attach(let settingsFrame):
            let visible = SystemSettingsWindowLocator.screen(
                containing: settingsFrame,
                screens: screens
            )?.visibleFrame ?? NSScreen.main?.visibleFrame ?? settingsFrame
            frame = PermissionGuideLayout.panelFrame(
                settingsFrame: settingsFrame,
                visibleFrame: visible,
                panelSize: Self.panelSize
            )
        case .showAtScreenBottom:
            let visible = NSScreen.main?.visibleFrame ?? .zero
            frame = PermissionGuideLayout.panelFrame(
                settingsFrame: visible.insetBy(dx: 80, dy: 70),
                visibleFrame: visible,
                panelSize: Self.panelSize
            )
        }
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
        }
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    /// Follows Settings window moves and resizes as they happen. Needs
    /// Accessibility access; without it the 30 Hz timer still tracks the window.
    private func observeSettingsWindowIfPossible(pid: pid_t) {
        guard observedSettingsPID != pid, AXIsProcessTrusted() else { return }
        stopObservingSettingsWindow()
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let controller = Unmanaged<PermissionGuideController>
                .fromOpaque(refcon)
                .takeUnretainedValue()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { controller.tick() }
            }
        }
        guard AXObserverCreate(pid, callback, &observer) == .success,
              let observer else {
            return
        }
        let application = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for notification in [
            kAXWindowMovedNotification,
            kAXWindowResizedNotification,
            kAXFocusedWindowChangedNotification,
            kAXMainWindowChangedNotification
        ] {
            _ = AXObserverAddNotification(observer, application, notification as CFString, refcon)
        }
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )
        windowObserver = observer
        observedSettingsPID = pid
    }

    private func stopObservingSettingsWindow() {
        if let windowObserver {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(windowObserver),
                .commonModes
            )
        }
        windowObserver = nil
        observedSettingsPID = nil
    }

    private static func screens() -> [PermissionGuideScreen] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else {
                return nil
            }
            return PermissionGuideScreen(
                appKitFrame: screen.frame,
                visibleFrame: screen.visibleFrame,
                cgBounds: CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
            )
        }
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        // Above System Settings, which belongs to another app.
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        return panel
    }
}

@MainActor
final class PermissionGuideModel: ObservableObject {
    let kind: PermissionGuideKind
    let appName: String
    let dragURL: URL
    @Published var isGranted = false

    init(kind: PermissionGuideKind, appName: String, dragURL: URL) {
        self.kind = kind
        self.appName = appName
        self.dragURL = dragURL
    }
}

private struct PermissionGuideView: View {
    @ObservedObject var model: PermissionGuideModel
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            AppIconDragSource(url: model.dragURL)
                .frame(width: 56, height: 56)
                .accessibilityLabel(
                    localizedCatalogFormat("Drag %@ to System Settings", model.appName)
                )

            VStack(alignment: .leading, spacing: 3) {
                if model.isGranted {
                    Label(localizedCatalogString("Granted"), systemImage: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.green)
                    Text(localizedCatalogString("This guide closes in a moment."))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    Text(localizedCatalogFormat("Drag %@ into the list above", model.appName))
                        .font(.system(size: 14, weight: .semibold))
                    Text(localizedCatalogString("Then turn on the switch next to it."))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    if model.kind == .screenRecording {
                        Text(localizedCatalogString("You may need to reopen the app after turning this on."))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(localizedCatalogString("Close"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 460, height: 104)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }
}

/// Quill's icon as a real file drag of the app bundle, so System Settings
/// adds this exact app when it is dropped into the permission list. AppKit
/// dragging works from a non-activating panel while Quill is in the background.
private struct AppIconDragSource: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AppIconDragView {
        AppIconDragView(url: url)
    }

    func updateNSView(_ nsView: AppIconDragView, context: Context) {
        nsView.url = url
    }
}

final class AppIconDragView: NSView, NSDraggingSource {
    var url: URL
    private var mouseDownLocation: NSPoint?

    init(url: URL) {
        self.url = url
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage.draw(in: bounds)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownLocation else { return }
        let location = event.locationInWindow
        guard hypot(location.x - start.x, location.y - start.y) > 3 else { return }
        mouseDownLocation = nil
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(bounds, contents: NSApp.applicationIconImage)
        // While dragging, let the drop reach System Settings even where this
        // panel overlaps its window.
        window?.ignoresMouseEvents = true
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        window?.ignoresMouseEvents = false
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .link, .generic] : []
    }
}
