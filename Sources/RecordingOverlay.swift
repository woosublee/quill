import SwiftUI
import AppKit

// MARK: - State

struct RecordingOverlayInputOption: Identifiable, Equatable {
    let id: String
    let name: String
}

final class RecordingOverlayState: ObservableObject {
    @Published var phase: OverlayPhase = .recording
    @Published var audioLevel: Float = 0.0
    @Published var recordingTriggerMode: RecordingTriggerMode = .hold
    @Published var recordingOverlayLayout: RecordingOverlayLayout = .centered
    @Published var isCommandMode = false
    @Published var updateVersion: String = ""
    @Published var errorMessage: String?
    @Published var toastID: UUID?
    @Published var inputOptions: [RecordingOverlayInputOption] = []
    @Published var selectedInputID: String = ""
    /// When the active recording effectively started (first captured audio),
    /// preserved across mid-recording input switches. Used for the hover timer.
    @Published var recordingStartedAt: Date?
    /// How the overlay presents the elapsed recording time relative to the waveform.
    @Published var waveformDisplayMode: OverlayWaveformDisplayMode = .waveformOnly
}

enum OverlayPhase {
    case initializing
    case recording
    case transcribing
    case feedback
    case updateAvailable
}

/// Controls how the recording overlay presents elapsed time relative to the
/// live audio waveform.
enum OverlayWaveformDisplayMode: String, CaseIterable, Identifiable {
    /// Show only the live waveform (default). No elapsed time.
    case waveformOnly
    /// Show the waveform; reveal elapsed time only while hovering it.
    case hoverTime
    /// Replace the waveform with a running elapsed-time counter.
    case timeOnly

    var id: String { rawValue }

    static func find(rawValue: String?) -> OverlayWaveformDisplayMode {
        guard let rawValue, let mode = OverlayWaveformDisplayMode(rawValue: rawValue) else {
            return .waveformOnly
        }
        return mode
    }
}

enum RecordingOverlayLayout: String, CaseIterable, Identifiable {
    case centered
    case notchSides

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .centered: return "Centered"
        case .notchSides: return "Notch Sides"
        }
    }

    var helpText: String {
        switch self {
        case .centered:
            return "Show the recording overlay centered below the notch."
        case .notchSides:
            return "Show recording status beside the notch when supported. Update alerts stay centered."
        }
    }

    static func find(rawValue: String?) -> RecordingOverlayLayout {
        guard let rawValue, let layout = RecordingOverlayLayout(rawValue: rawValue) else { return .centered }
        return layout
    }
}

// MARK: - NSScreen Helpers

extension Dictionary where Key == NSDeviceDescriptionKey, Value == Any {
    var displayID: CGDirectDisplayID? {
        (self[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

extension NSScreen {
    /// CoreGraphics display identifier for this screen, or nil if the device
    /// description is missing the key.
    var displayID: CGDirectDisplayID? {
        deviceDescription.displayID
    }
}

// MARK: - Panel Helpers

private func makeOverlayPanel(width: CGFloat, height: CGFloat) -> NSPanel {
    let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: width, height: height),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = true
    panel.level = .screenSaver
    panel.ignoresMouseEvents = true
    panel.collectionBehavior = [.canJoinAllSpaces]
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false
    return panel
}

private func makeNotchContent<V: View>(
    width: CGFloat,
    height: CGFloat,
    cornerRadius: CGFloat,
    rootView: V
) -> NSView {
    let shaped = rootView
        .frame(width: width, height: height)
        .background(Color.black)
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: cornerRadius, bottomTrailingRadius: cornerRadius))

    let size = NSSize(width: width, height: height)
    let hosting = FixedIntrinsicHostingView(rootView: shaped, size: size)
    hosting.frame = NSRect(origin: .zero, size: size)
    hosting.autoresizingMask = [.width, .height]
    return hosting
}

private func makeTransparentContent<V: View>(
    width: CGFloat,
    height: CGFloat,
    rootView: V
) -> NSView {
    let size = NSSize(width: width, height: height)
    let hosting = FixedIntrinsicHostingView(rootView: rootView.frame(width: width, height: height), size: size)
    hosting.frame = NSRect(origin: .zero, size: size)
    hosting.autoresizingMask = [.width, .height]
    return hosting
}

struct RecordingOverlayGeometry {
    static func lockedTranscribingWidth(
        existingLockedWidth: CGFloat?,
        currentPanelWidth: CGFloat,
        centeredTranscribingWidth: CGFloat,
        wasNotchSideRecordingLayout: Bool
    ) -> CGFloat {
        if let existingLockedWidth { return existingLockedWidth }
        return wasNotchSideRecordingLayout ? centeredTranscribingWidth : currentPanelWidth
    }

    static func usesNotchSideLayout(
        layout: RecordingOverlayLayout,
        phase: OverlayPhase,
        hasNotchGeometry: Bool,
        hasErrorMessage: Bool = false
    ) -> Bool {
        guard layout == .notchSides, hasNotchGeometry else { return false }

        switch phase {
        case .initializing, .recording, .transcribing:
            return true
        case .feedback:
            return !hasErrorMessage
        case .updateAvailable:
            return false
        }
    }
}

// MARK: - Manager

final class RecordingOverlayManager {
    private var overlayWindow: NSPanel?
    private let overlayState = RecordingOverlayState()
    private var lockedOverlayWidth: CGFloat?
    private var screenParametersObserver: NSObjectProtocol?
    /// Separate panel for transient recording notices (e.g. a rejected input
    /// switch). Anchored just below the overlay stack so it never overlaps the
    /// live waveform or a visible reminder card.
    private var noticeWindow: NSPanel?
    /// Identifies the in-flight notice so its scheduled dismissal only fires if
    /// that same notice is still showing.
    private var noticeToken: UUID?
    private let notchSideRegionWidth: CGFloat = 92
    private let notchSidePanelHeight: CGFloat = 38
    private let notchSideHorizontalInset: CGFloat = 8

    private typealias NotchSideGeometry = OverlayScreenGeometry.NotchSideGeometry
    private static let maxToastMessageLength = 90
    /// Fixed height of the centered pill on notched displays (sits below the notch).
    private static let overlayPillHeight: CGFloat = 38

    var onStopButtonPressed: (() -> Void)?
    var onUpdateOverlayPressed: (() -> Void)?
    var onSelectInput: ((String) -> Void)?

    func updateInputOptions(_ options: [RecordingOverlayInputOption], selectedID: String) {
        overlayState.inputOptions = options
        overlayState.selectedInputID = selectedID
    }

    func setRecordingStartedAt(_ date: Date?) {
        overlayState.recordingStartedAt = date
    }

    func setWaveformDisplayMode(_ mode: OverlayWaveformDisplayMode) {
        DispatchQueue.main.async {
            self.overlayState.waveformDisplayMode = mode
        }
    }

    init() {
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleScreenParametersChanged()
        }
    }

    deinit {
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
        }
    }

    /// The screen the overlay should drop down on. The user picks one of
    /// three modes in Settings, stored in UserDefaults under
    /// `overlay_display_id`:
    ///
    /// - `0` (default) — Active window: follows focus across monitors via
    ///   NSScreen.main.
    /// - `-1` — Primary display: always NSScreen.screens.first.
    /// - any positive integer — specific NSScreen displayID. Falls back to
    ///   primary if that display is unplugged.
    private var targetScreen: NSScreen? {
        let savedID = UserDefaults.standard.integer(forKey: "overlay_display_id")
        switch savedID {
        case 0:
            return NSScreen.main ?? NSScreen.screens.first
        case -1:
            return NSScreen.screens.first ?? NSScreen.main
        default:
            if let match = NSScreen.screens.first(where: { Int($0.displayID ?? 0) == savedID }) {
                return match
            }
            return NSScreen.screens.first ?? NSScreen.main
        }
    }

    private var screenGeometry: OverlayScreenGeometry? {
        guard let screen = targetScreen else { return nil }
        return OverlayScreenGeometry(screen: screen)
    }

    private var screenHasTopSafeArea: Bool {
        screenGeometry?.hasTopSafeArea ?? false
    }

    private var notchWidth: CGFloat {
        screenGeometry?.notchWidth ?? 0
    }

    private var notchOverlap: CGFloat {
        screenGeometry?.notchOverlap ?? 0
    }

    private var usesNotchSideLayout: Bool {
        RecordingOverlayGeometry.usesNotchSideLayout(
            layout: overlayState.recordingOverlayLayout,
            phase: overlayState.phase,
            hasNotchGeometry: notchSideGeometry != nil,
            hasErrorMessage: overlayState.errorMessage?.isEmpty == false
        )
    }

    private var notchSideGeometry: NotchSideGeometry? {
        screenGeometry?.notchSideGeometry(
            regionWidth: notchSideRegionWidth,
            panelHeight: notchSidePanelHeight,
            horizontalInset: notchSideHorizontalInset
        )
    }

    private var overlayAcceptsMouseEvents: Bool {
        (overlayState.phase == .recording && overlayState.recordingTriggerMode == .toggle)
            || overlayState.phase == .updateAvailable
    }

    func showInitializing(mode: RecordingTriggerMode = .hold, isCommandMode: Bool = false) {
        DispatchQueue.main.async {
            self.lockedOverlayWidth = nil
            self.overlayState.recordingTriggerMode = mode
            self.overlayState.isCommandMode = isCommandMode
            self.overlayState.phase = .initializing
            self.overlayState.audioLevel = 0
            self.showOverlayPanel(animatedResize: false)
        }
    }

    func showRecording(mode: RecordingTriggerMode = .hold, isCommandMode: Bool = false) {
        DispatchQueue.main.async {
            self.lockedOverlayWidth = nil
            self.overlayState.recordingTriggerMode = mode
            self.overlayState.isCommandMode = isCommandMode
            self.overlayState.phase = .recording
            self.overlayState.audioLevel = 0
            self.showOverlayPanel(animatedResize: true)
        }
    }

    func transitionToRecording(mode: RecordingTriggerMode = .hold, isCommandMode: Bool = false) {
        DispatchQueue.main.async {
            self.lockedOverlayWidth = nil
            self.overlayState.recordingTriggerMode = mode
            self.overlayState.isCommandMode = isCommandMode
            self.overlayState.phase = .recording
            self.updateOverlayLayout(animated: true)
        }
    }

    func setRecordingTriggerMode(_ mode: RecordingTriggerMode, animated: Bool) {
        DispatchQueue.main.async {
            self.overlayState.recordingTriggerMode = mode
            self.updateOverlayLayout(animated: animated)
        }
    }

    func setRecordingOverlayLayout(_ layout: RecordingOverlayLayout) {
        DispatchQueue.main.async {
            self.overlayState.recordingOverlayLayout = layout
            self.updateOverlayLayout(animated: false)
        }
    }

    func updateAudioLevel(_ level: Float) {
        DispatchQueue.main.async {
            self.overlayState.audioLevel = level
        }
    }

    func showTranscribing() {
        DispatchQueue.main.async {
            self.setTranscribingPhase()
        }
    }

    func showFailureIndicator() {
        DispatchQueue.main.async {
            self.overlayState.errorMessage = nil
            self.overlayState.toastID = nil
            self.showFeedbackPanel()
        }
    }

    private static func truncatedToastMessage(_ message: String) -> String {
        guard message.count > maxToastMessageLength else { return message }
        let cutoff = message.index(message.startIndex, offsetBy: maxToastMessageLength - 1)
        return String(message[..<cutoff]) + "…"
    }

    /// Surface a transient error in the menu-bar pill. The pill resizes to fit
    /// the message, holds briefly, then dismisses.
    func showError(_ message: String) {
        let truncated = Self.truncatedToastMessage(message)
        DispatchQueue.main.async {
            let toastID = UUID()
            self.overlayState.errorMessage = truncated
            self.overlayState.toastID = toastID
            self.lockedOverlayWidth = nil
            self.overlayState.phase = .feedback
            self.showOverlayPanel(animatedResize: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self] in
                guard let self else { return }
                guard self.overlayState.phase == .feedback,
                      self.overlayState.errorMessage == truncated,
                      self.overlayState.toastID == toastID else {
                    return
                }
                self.overlayState.errorMessage = nil
                self.overlayState.toastID = nil
                self.dismissAll()
            }
        }
    }

    /// Frame of the recording overlay panel while it's on screen, else nil.
    /// Used to anchor the transient notice toast below the overlay stack.
    var visibleOverlayFrame: NSRect? {
        guard let overlayWindow, overlayWindow.isVisible, overlayWindow.alphaValue > 0 else { return nil }
        return overlayWindow.frame
    }

    /// Surface a transient notice for a non-fatal mid-recording event (e.g. a
    /// rejected input switch) WITHOUT ending the session: a separate toast
    /// anchored just under the lowest visible overlay (the recording pill, or
    /// the taller reminder card when `reminderFrame` is set) so it never covers
    /// the live waveform or overlaps the reminder.
    func showRecordingNotice(_ message: String, reminderFrame: NSRect?) {
        let truncated = Self.truncatedToastMessage(message)
        DispatchQueue.main.async {
            guard self.overlayState.phase == .recording,
                  let anchor = self.noticeAnchorFrame(reminderFrame: reminderFrame) else {
                // No recording overlay on screen — fall back to the standard toast.
                self.showError(message)
                return
            }
            self.showAnchoredRecordingNotice(truncated, anchor: anchor)
        }
    }

    /// Bottom-most visible overlay frame (recording pill vs. the taller reminder
    /// card), used as the anchor for the toast. Smaller minY = lower on screen.
    private func noticeAnchorFrame(reminderFrame: NSRect?) -> NSRect? {
        // Only anchor to actually-visible frames so the toast never attaches to
        // a stale/hidden overlay position.
        [visibleOverlayFrame, reminderFrame]
            .compactMap { $0 }
            .min(by: { $0.minY < $1.minY })
    }

    /// Show a standalone toast panel just below `anchor`, matching its width but
    /// never narrower than the message needs.
    private func showAnchoredRecordingNotice(_ truncated: String, anchor: NSRect) {
        let token = UUID()
        noticeToken = token

        let height: CGFloat = 30
        let gap: CGFloat = 6
        let estimatedFit = CGFloat(truncated.count) * 6.8 + 44
        let minFit = min(420, max(220, estimatedFit))
        var width = max(anchor.width, minFit)
        if let screenWidth = screenGeometry?.screenFrame.width {
            width = min(width, screenWidth - 32)
        }
        let frame = NSRect(
            x: anchor.midX - width / 2,
            y: anchor.minY - gap - height,
            width: width,
            height: height
        )

        let panel = noticeWindow ?? makeOverlayPanel(width: frame.width, height: frame.height)
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.contentView = makeTransparentContent(
            width: frame.width,
            height: frame.height,
            rootView: RecordingNoticeToastView(message: truncated)
        )
        // Reuse keeps the panel on screen; only reset alpha when it's actually
        // hidden, otherwise replacing a still-visible notice flashes.
        let isAlreadyVisible = panel.isVisible && panel.alphaValue > 0
        panel.setFrame(frame, display: true)
        if !isAlreadyVisible {
            panel.alphaValue = 0
        }
        panel.orderFrontRegardless()
        noticeWindow = panel

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            panel.animator().alphaValue = 1
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            guard let self, self.noticeToken == token else { return }
            self.noticeToken = nil
            self.dismissNoticeToast()
        }
    }

    private func dismissNoticeToast() {
        guard let panel = noticeWindow else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self, weak panel] in
            // A newer notice may have been scheduled mid-fade; only hide the
            // panel if nothing is showing now.
            guard let self, self.noticeToken == nil else { return }
            panel?.orderOut(nil)
        })
    }

    func showUpdateAvailable(version: String) {
        DispatchQueue.main.async {
            self.lockedOverlayWidth = nil
            self.overlayState.isCommandMode = false
            self.overlayState.updateVersion = version
            self.overlayState.phase = .updateAvailable
            self.showOverlayPanel(animatedResize: true)
        }
    }

    func dismiss() {
        DispatchQueue.main.async {
            self.dismissAll()
        }
    }

    private func showOverlayPanel(animatedResize: Bool) {
        let frame = overlayFrame

        if let panel = overlayWindow {
            panel.ignoresMouseEvents = !overlayAcceptsMouseEvents
            panel.contentView = makeOverlayContent(frame: frame)
            resize(panel: panel, to: frame, animated: animatedResize)
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            return
        }

        let panel = makeOverlayPanel(width: frame.width, height: frame.height)
        panel.hasShadow = false
        panel.ignoresMouseEvents = !overlayAcceptsMouseEvents
        panel.contentView = makeOverlayContent(frame: frame)

        guard let screen = targetScreen else { return }

        let hiddenFrame = NSRect(x: frame.origin.x, y: screen.frame.maxY, width: frame.width, height: frame.height)
        panel.setFrame(hiddenFrame, display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.56, 0.64, 1.0)
            panel.animator().setFrame(frame, display: true)
        }

        overlayWindow = panel
    }

    private func updateOverlayLayout(animated: Bool) {
        guard let panel = overlayWindow else { return }
        let frame = overlayFrame
        panel.ignoresMouseEvents = !overlayAcceptsMouseEvents
        panel.contentView = makeOverlayContent(frame: frame)
        resize(panel: panel, to: frame, animated: animated)
    }

    private func handleScreenParametersChanged() {
        updateOverlayLayout(animated: false)
    }

    private func setTranscribingPhase() {
        let wasNotchSideRecordingLayout = overlayState.phase == .recording && usesNotchSideLayout
        lockedOverlayWidth = RecordingOverlayGeometry.lockedTranscribingWidth(
            existingLockedWidth: lockedOverlayWidth,
            currentPanelWidth: overlayWindow?.frame.width ?? overlayWidth,
            centeredTranscribingWidth: centeredTranscribingOverlayWidth,
            wasNotchSideRecordingLayout: wasNotchSideRecordingLayout
        )
        overlayState.phase = .transcribing
        showOverlayPanel(animatedResize: true)
    }

    private func makeOverlayContent(frame: NSRect) -> NSView {
        if let geometry = notchSideGeometry,
           usesNotchSideLayout {
            return makeNotchSideContent(frame: frame, geometry: geometry)
        }

        return makeNotchContent(
            width: frame.width,
            height: frame.height,
            cornerRadius: screenHasTopSafeArea ? 18 : 12,
            rootView: RecordingOverlayView(
                state: overlayState,
                onStopButtonPressed: { [weak self] in
                    self?.onStopButtonPressed?()
                },
                onUpdateOverlayPressed: { [weak self] in
                    self?.onUpdateOverlayPressed?()
                },
                onSelectInput: { [weak self] id in
                    self?.onSelectInput?(id)
                }
            )
            .padding(.top, screenHasTopSafeArea ? notchOverlap : 0)
        )
    }

    private func makeNotchSideContent(frame: NSRect, geometry: NotchSideGeometry) -> NSView {
        makeTransparentContent(
            width: frame.width,
            height: frame.height,
            rootView: NotchSideOverlayView(
                state: overlayState,
                leftContentFrame: geometry.leftContentFrame,
                rightContentFrame: geometry.rightContentFrame,
                onStopButtonPressed: { [weak self] in
                    self?.onStopButtonPressed?()
                },
                onSelectInput: { [weak self] id in
                    self?.onSelectInput?(id)
                }
            )
        )
    }

    private func resize(panel: NSPanel, to frame: NSRect, animated: Bool) {
        guard animated else {
            panel.setFrame(frame, display: true)
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(frame, display: true)
        }
    }

    private var overlayFrame: NSRect {
        guard let screenGeometry else { return .zero }
        if let geometry = notchSideGeometry,
           usesNotchSideLayout {
            return geometry.frame
        }

        let width = overlayWidth
        let height: CGFloat
        if screenHasTopSafeArea {
            // Notched displays: the pill sits below the notch/menu bar, so add
            // the menu bar gap on top of the fixed pill height.
            height = Self.overlayPillHeight + notchOverlap
        } else {
            // No notch: match the menu bar height so the overlay occupies exactly
            // the menu bar area instead of overflowing below it. This is shared
            // with the reminder overlay's top strip so the two stay aligned when
            // shown together. The overlay content is <=20pt tall, so the floor
            // keeps it from clipping.
            height = screenGeometry.menuBarStripHeight
        }
        return screenGeometry.centeredTopFrame(width: width, height: height)
    }

    private var centeredTranscribingOverlayWidth: CGFloat {
        let defaultWidth: CGFloat = 92
        guard screenHasTopSafeArea else { return defaultWidth }
        return max(notchWidth, defaultWidth)
    }

    private var overlayWidth: CGFloat {
        if let lockedOverlayWidth, overlayState.phase == .transcribing {
            return lockedOverlayWidth
        }

        if overlayState.phase == .feedback {
            let feedbackWidth: CGFloat = {
                guard let message = overlayState.errorMessage, !message.isEmpty else {
                    return 92
                }
                let estimated = CGFloat(message.count) * 6.8 + 60
                return min(420, max(180, estimated))
            }()
            guard screenHasTopSafeArea else { return feedbackWidth }
            return max(notchWidth, feedbackWidth)
        }

        if overlayState.phase == .updateAvailable {
            let updateWidth: CGFloat = 190
            guard screenHasTopSafeArea else { return updateWidth }
            return max(notchWidth, updateWidth)
        }

        let commandModeWidth: CGFloat = 180
        let toggleWidth: CGFloat = 150
        let defaultWidth: CGFloat = 92
        let baseWidth: CGFloat

        if overlayState.isCommandMode {
            baseWidth = commandModeWidth
        } else if overlayState.phase == .recording && overlayState.recordingTriggerMode == .toggle {
            baseWidth = toggleWidth
        } else {
            baseWidth = defaultWidth
        }

        guard screenHasTopSafeArea else { return baseWidth }
        return max(notchWidth, baseWidth)
    }

    private func showFeedbackPanel() {
        lockedOverlayWidth = nil
        overlayState.phase = .feedback
        showOverlayPanel(animatedResize: true)
    }

    private func dismissAll() {
        lockedOverlayWidth = nil
        overlayState.isCommandMode = false
        overlayState.updateVersion = ""
        if let panel = overlayWindow {
            panel.orderOut(nil)
            // orderOut alone leaves the panel retained in NSApp.windows with its
            // SwiftUI hierarchy mounted — repeatForever animations keep flushing
            // Core Animation forever. Unmount and close so the panel deallocates.
            panel.contentView = nil
            panel.close()
            overlayWindow = nil
        }
        // Tear down any transient notice toast alongside the overlay so it
        // doesn't linger after the session ends.
        noticeToken = nil
        noticeWindow?.orderOut(nil)
    }
}

// MARK: - Waveform Views

struct WaveformBar: View {
    let amplitude: CGFloat

    private let minHeight: CGFloat = 2
    private let maxHeight: CGFloat = 20

    var body: some View {
        Capsule()
            .fill(.white)
            .frame(width: 3, height: minHeight + (maxHeight - minHeight) * amplitude)
    }
}

struct WaveformView: View {
    let audioLevel: Float
    var showsActivityPulse = false

    private static let barCount = 9
    private static let multipliers: [CGFloat] = [0.35, 0.55, 0.75, 0.9, 1.0, 0.9, 0.75, 0.55, 0.35]
    private static let centerIndex = CGFloat((barCount - 1) / 2)

    var body: some View {
        Group {
            if showsActivityPulse {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
                    waveformBars(pulseTime: context.date.timeIntervalSinceReferenceDate)
                }
            } else {
                waveformBars(pulseTime: nil)
            }
        }
        .frame(height: 20)
    }

    private func waveformBars(pulseTime: TimeInterval?) -> some View {
        HStack(spacing: 2.5) {
            ForEach(0..<Self.barCount, id: \.self) { index in
                WaveformBar(amplitude: barAmplitude(for: index, pulseTime: pulseTime))
                    .animation(
                        .spring(
                            response: barResponse(for: index),
                            dampingFraction: 0.88
                        )
                        .delay(barDelay(for: index)),
                        value: audioLevel
                    )
            }
        }
    }

    private func barAmplitude(for index: Int, pulseTime: TimeInterval?) -> CGFloat {
        let level = CGFloat(max(audioLevel, 0))
        let baseAmplitude = min(level * Self.multipliers[index], 1.0)

        guard let pulseTime else { return baseAmplitude }

        let travelingWave = CGFloat(0.5 + 0.5 * sin((pulseTime * 6.2) - Double(index) * 0.78))
        let shimmer = CGFloat(0.5 + 0.5 * sin((pulseTime * 3.1) + Double(index) * 0.5))
        let pulse = travelingWave * 0.22 + shimmer * 0.06

        let saturationRelief = baseAmplitude * (0.74 + pulse)
        let quietPulse = (1.0 - baseAmplitude) * (0.04 + pulse * 0.28)
        return min(saturationRelief + quietPulse, 1.0)
    }

    private func barResponse(for index: Int) -> Double {
        let distance = abs(CGFloat(index) - Self.centerIndex)
        let normalizedDistance = distance / Self.centerIndex
        return 0.18 + Double(normalizedDistance) * 0.06
    }

    private func barDelay(for index: Int) -> Double {
        let distance = abs(CGFloat(index) - Self.centerIndex)
        return Double(distance) * 0.01
    }
}

struct CompactWaveformView: View {
    let audioLevel: Float
    var showsActivityPulse = false

    var body: some View {
        WaveformView(audioLevel: audioLevel, showsActivityPulse: showsActivityPulse)
    }
}

struct CompactProcessingIndicatorView: View {
    var body: some View {
        ProcessingWaveformView()
    }
}

struct ProcessingWaveformView: View {
    private static let barCount = 5
    private static let centerIndex = CGFloat((barCount - 1) / 2)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
            let time = context.date.timeIntervalSinceReferenceDate

            HStack(spacing: 4) {
                ForEach(0..<Self.barCount, id: \.self) { index in
                    ProcessingPill(
                        amplitude: amplitude(for: index, time: time),
                        opacity: opacity(for: index, time: time)
                    )
                }
            }
            .frame(height: 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func phase(for index: Int, time: TimeInterval) -> Double {
        let cycle = 1.05
        let stagger = 0.11
        return ((time - Double(index) * stagger).truncatingRemainder(dividingBy: cycle)) / cycle
    }

    private func pulse(for index: Int, time: TimeInterval) -> CGFloat {
        let phase = phase(for: index, time: time)
        let wave = 0.5 + 0.5 * sin((phase * 2.0 * .pi) - (.pi / 2.0))
        return CGFloat(pow(wave, 1.9))
    }

    private func amplitude(for index: Int, time: TimeInterval) -> CGFloat {
        let centerDistance = abs(CGFloat(index) - Self.centerIndex) / Self.centerIndex
        let baseline = 0.18 + (1.0 - centerDistance) * 0.1
        return min(baseline + pulse(for: index, time: time) * 0.68, 1.0)
    }

    private func opacity(for index: Int, time: TimeInterval) -> CGFloat {
        0.42 + pulse(for: index, time: time) * 0.52
    }
}

private struct ProcessingPill: View {
    let amplitude: CGFloat
    let opacity: CGFloat

    private let minHeight: CGFloat = 4
    private let maxHeight: CGFloat = 18

    var body: some View {
        Capsule()
            .fill(.white)
            .frame(width: 4, height: minHeight + (maxHeight - minHeight) * amplitude)
            .opacity(opacity)
    }
}

struct ProcessingIndicatorView: View {
    @State private var showsExtendedSpinner = false
    @State private var rotation: Double = 0

    var body: some View {
        ZStack {
            if showsExtendedSpinner {
                Circle()
                    .trim(from: 0.1, to: 0.9)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .frame(width: 16, height: 16)
                    .rotationEffect(.degrees(rotation))
                    .frame(height: 20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    .onAppear {
                        rotation = 0
                        withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                            rotation = 360
                        }
                    }
            } else {
                ProcessingWaveformView()
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .task {
            showsExtendedSpinner = false
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.18)) {
                    showsExtendedSpinner = true
                }
            } catch {}
        }
    }
}

struct InitializingDotsView: View {
    @State private var activeDot = 0
    @State private var timer: Timer?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(.white.opacity(activeDot == index ? 0.9 : 0.25))
                    .frame(width: 4.5, height: 4.5)
                    .animation(.easeInOut(duration: 0.4), value: activeDot)
            }
        }
        .onAppear {
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                DispatchQueue.main.async {
                    activeDot = (activeDot + 1) % 3
                }
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }
}

private struct NotchExtensionBackground: View {
    var body: some View {
        Color.black
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: 12,
                    bottomTrailingRadius: 12,
                    topTrailingRadius: 0,
                    style: .continuous
                )
            )
    }
}

private struct NotchSideOverlayView: View {
    @ObservedObject var state: RecordingOverlayState
    let leftContentFrame: CGRect
    let rightContentFrame: CGRect
    let onStopButtonPressed: () -> Void
    let onSelectInput: (String) -> Void

    private var showsLiveRecordingContent: Bool {
        state.phase == .recording
    }

    private var showsStopButton: Bool {
        showsLiveRecordingContent && state.recordingTriggerMode == .toggle
    }

    private var showsInputSwitcher: Bool {
        showsLiveRecordingContent
            && state.recordingTriggerMode == .toggle
            && !state.inputOptions.isEmpty
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            NotchExtensionBackground()

            leftContent
                .frame(width: leftContentFrame.width, height: leftContentFrame.height)
                .position(x: leftContentFrame.midX, y: leftContentFrame.midY)

            rightContent
                .frame(width: rightContentFrame.width, height: rightContentFrame.height)
                .position(x: rightContentFrame.midX, y: rightContentFrame.midY)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: state.phase)
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: state.recordingTriggerMode)
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: state.isCommandMode)
    }

    @ViewBuilder
    private var leftContent: some View {
        ZStack {
            switch state.phase {
            case .initializing:
                InitializingDotsView()
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            case .recording:
                VStack(spacing: 1) {
                    if state.isCommandMode {
                        Image(systemName: "pencil")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.92))
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }
                    if showsInputSwitcher {
                        InputSwitchMenu(
                            options: state.inputOptions,
                            selectedID: state.selectedInputID,
                            onSelect: onSelectInput,
                            recordingStartedAt: state.recordingStartedAt,
                            displayMode: state.waveformDisplayMode
                        ) {
                            CompactWaveformView(audioLevel: state.audioLevel, showsActivityPulse: true)
                        }
                    } else {
                        CompactWaveformView(audioLevel: state.audioLevel, showsActivityPulse: true)
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            case .transcribing:
                CompactProcessingIndicatorView()
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            case .feedback, .updateAvailable:
                Color.clear
            }
        }
        .padding(.horizontal, 12)
    }

    @ViewBuilder
    private var rightContent: some View {
        ZStack {
            switch state.phase {
            case .recording:
                if showsStopButton {
                    Button(action: onStopButtonPressed) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(Color.red.opacity(0.92)))
                    }
                    .buttonStyle(.plain)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            case .feedback:
                FailureIndicatorView()
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            case .initializing, .transcribing, .updateAvailable:
                Color.clear
            }
        }
    }
}

struct RecordingOverlayView: View {
    @ObservedObject var state: RecordingOverlayState
    let onStopButtonPressed: () -> Void
    let onUpdateOverlayPressed: () -> Void
    let onSelectInput: (String) -> Void

    private let leadingAccessoryWidth: CGFloat = 24
    private let trailingAccessoryWidth: CGFloat = 32

    private var showsLiveRecordingContent: Bool {
        state.phase == .recording
    }

    private var showsStopButton: Bool {
        showsLiveRecordingContent && state.recordingTriggerMode == .toggle
    }

    private var showsInputSwitcher: Bool {
        showsLiveRecordingContent
            && state.recordingTriggerMode == .toggle
            && !state.inputOptions.isEmpty
    }

    var body: some View {
        Group {
            if state.phase == .feedback, let message = state.errorMessage {
                ErrorOverlayView(message: message)
            } else if state.phase == .feedback {
                FailureIndicatorView()
            } else if state.phase == .updateAvailable {
                UpdateAvailableOverlayView(onPress: onUpdateOverlayPressed)
            } else {
                ZStack {
                    Group {
                        if state.phase == .initializing {
                            InitializingDotsView()
                                .transition(.opacity)
                        } else if showsLiveRecordingContent {
                            if showsInputSwitcher {
                                InputSwitchMenu(
                                    options: state.inputOptions,
                                    selectedID: state.selectedInputID,
                                    onSelect: onSelectInput,
                                    recordingStartedAt: state.recordingStartedAt,
                                    displayMode: state.waveformDisplayMode
                                ) {
                                    WaveformView(audioLevel: state.audioLevel, showsActivityPulse: true)
                                }
                                .transition(.opacity)
                            } else {
                                WaveformView(
                                    audioLevel: state.audioLevel,
                                    showsActivityPulse: state.phase == .recording
                                )
                                .transition(.opacity)
                            }
                        } else {
                            ProcessingIndicatorView()
                                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                        }
                    }

                    HStack {
                        Group {
                            if state.isCommandMode {
                                CommandModeIndicator()
                                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                            }
                        }
                        .frame(width: leadingAccessoryWidth, alignment: .center)
                        .frame(maxHeight: .infinity, alignment: .center)

                        Spacer(minLength: 0)

                        Group {
                            if showsStopButton {
                                Button(action: onStopButtonPressed) {
                                    Image(systemName: "stop.fill")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.white)
                                        .frame(width: 20, height: 20)
                                        .background(Circle().fill(Color.red.opacity(0.92)))
                                }
                                .buttonStyle(.plain)
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                            }
                        }
                        .frame(width: trailingAccessoryWidth, alignment: .trailing)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: state.phase)
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: state.recordingTriggerMode)
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: state.isCommandMode)
    }
}

/// Wraps overlay content (the waveform) so hovering it peeks the elapsed
/// recording time (in the same footprint) and clicking it opens a menu to switch
/// the audio input mid-recording. Uses an AppKit NSMenu + tracking area (via a
/// transparent catcher) because SwiftUI's `Menu`/`.onHover` do not work reliably
/// inside the borderless, non-activating overlay panel.
struct InputSwitchMenu<Content: View>: View {
    let options: [RecordingOverlayInputOption]
    let selectedID: String
    let onSelect: (String) -> Void
    let recordingStartedAt: Date?
    let displayMode: OverlayWaveformDisplayMode
    @ViewBuilder var content: () -> Content
    @State private var isHovering = false

    /// Whether elapsed time is shown instead of the waveform right now.
    /// - `.waveformOnly`: never.
    /// - `.hoverTime`: only while hovering.
    /// - `.timeOnly`: always (waveform hidden for the whole recording).
    private var showsTime: Bool {
        guard recordingStartedAt != nil else { return false }
        switch displayMode {
        case .waveformOnly: return false
        case .hoverTime: return isHovering
        case .timeOnly: return true
        }
    }

    private var helpText: String {
        switch displayMode {
        case .timeOnly: return "Elapsed time · click to switch audio input"
        case .hoverTime: return "Hover for elapsed time · click to switch audio input"
        case .waveformOnly: return "Switch audio input"
        }
    }

    var body: some View {
        // Both views are always laid out (only opacity toggles) so the view's
        // size stays fixed when hovering. Otherwise the hover-tracked area would
        // resize as content swaps, making the mouse cross its edge and flicker
        // enter/exit (and sometimes get stuck "entered").
        ZStack {
            // In .timeOnly the waveform never shows, so omit it entirely rather
            // than keeping it at opacity 0 — otherwise its TimelineView keeps
            // ticking (and redrawing) invisibly. The other modes keep it laid
            // out so the hover-tracked area doesn't resize when time appears.
            if displayMode != .timeOnly {
                content()
                    .opacity(showsTime ? 0 : 1)
            }
            if let recordingStartedAt {
                ElapsedTimeView(startedAt: recordingStartedAt)
                    .opacity(showsTime ? 1 : 0)
            }
        }
        .animation(.easeInOut(duration: 0.12), value: showsTime)
        .overlay(
            InputMenuClickCatcher(
                options: options,
                selectedID: selectedID,
                onSelect: onSelect,
                onHoverChange: { hovering in isHovering = hovering }
            )
        )
        .help(helpText)
    }
}

/// Shows the elapsed recording time, ticking each second, as M:SS (or H:MM:SS
/// once it passes an hour).
private struct ElapsedTimeView: View {
    let startedAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(Self.formatted(context.date.timeIntervalSince(startedAt)))
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize()
        }
    }

    static func formatted(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

private struct InputMenuClickCatcher: NSViewRepresentable {
    let options: [RecordingOverlayInputOption]
    let selectedID: String
    let onSelect: (String) -> Void
    let onHoverChange: (Bool) -> Void

    func makeNSView(context: Context) -> ClickCatcherView {
        let view = ClickCatcherView()
        view.apply(options: options, selectedID: selectedID, onSelect: onSelect, onHoverChange: onHoverChange)
        return view
    }

    func updateNSView(_ nsView: ClickCatcherView, context: Context) {
        nsView.apply(options: options, selectedID: selectedID, onSelect: onSelect, onHoverChange: onHoverChange)
    }

    final class ClickCatcherView: NSView {
        private var options: [RecordingOverlayInputOption] = []
        private var selectedID: String = ""
        private var onSelect: ((String) -> Void)?
        private var onHoverChange: ((Bool) -> Void)?
        private var hoverTrackingArea: NSTrackingArea?

        func apply(
            options: [RecordingOverlayInputOption],
            selectedID: String,
            onSelect: @escaping (String) -> Void,
            onHoverChange: @escaping (Bool) -> Void
        ) {
            self.options = options
            self.selectedID = selectedID
            self.onSelect = onSelect
            self.onHoverChange = onHoverChange
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let hoverTrackingArea {
                removeTrackingArea(hoverTrackingArea)
            }
            // .activeAlways so hover fires even though the overlay panel never
            // becomes key; .inVisibleRect keeps it sized to the view.
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            hoverTrackingArea = area
        }

        override func mouseEntered(with event: NSEvent) {
            onHoverChange?(true)
        }

        override func mouseExited(with event: NSEvent) {
            onHoverChange?(false)
        }

        override func mouseDown(with event: NSEvent) {
            guard !options.isEmpty else { return }
            let menu = NSMenu()
            for option in options {
                let item = NSMenuItem(title: option.name, action: #selector(selectOption(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = option.id
                item.state = AudioInputDevice.isSameInput(option.id, selectedID) ? .on : .off
                menu.addItem(item)
            }
            // Anchor just below the view's bottom-left so the menu drops downward
            // consistently (NSView is not flipped, so y grows upward).
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: self)
        }

        @objc private func selectOption(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? String else { return }
            onSelect?(id)
        }
    }
}

// MARK: - Transcribing Indicator

struct CommandModeIndicator: View {
    var body: some View {
        Image(systemName: "pencil")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(0.92))
            .frame(width: 16, height: 16, alignment: .center)
    }
}

struct FailureIndicatorView: View {
    var body: some View {
        Image(systemName: "xmark")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(Circle().fill(Color.red.opacity(0.92)))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// In-pill error toast rendered inside the standard menu-bar pill.
struct ErrorOverlayView: View {
    let message: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.red.opacity(0.92))
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

/// Standalone transient toast for non-fatal mid-recording notices, shown in its
/// own panel anchored below the overlay stack. Draws its own rounded background
/// since the panel itself is transparent.
struct RecordingNoticeToastView: View {
    let message: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.red.opacity(0.92))
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black)
        )
    }
}

struct UpdateAvailableOverlayView: View {
    let onPress: () -> Void

    var body: some View {
        Button(action: onPress) {
            HStack(spacing: 7) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)

                Text("Update Available")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(.plain)
    }
}
