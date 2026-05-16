import AppKit
import SwiftUI

struct MeetingReminderOverlayContext: Equatable {
    var phase: Phase
    var layout: Layout

    enum Phase: Equatable {
        case idle
        case recording
        case processing
    }

    enum Layout: Equatable {
        case centerDropdownFill
        case notchSides
    }
}

enum MeetingReminderOverlayVariant: Equatable {
    case defaultReminder
    case notchSidesRecording
    case notchSidesProcessing
    case notchCenterRecording
    case notchCenterProcessing
    case centerRecording
    case centerProcessing

    var isRecordingContext: Bool {
        self != .defaultReminder
    }
}

struct MeetingReminderOverlayGeometry {
    static let defaultSize = CGSize(width: 336, height: 92)
    static let horizontalScreenMargin: CGFloat = 16
    static let notchSideHeight: CGFloat = 88
    static let notchCenterSize = CGSize(width: 388, height: 112)

    private static let notchSideRegionWidth: CGFloat = 92
    private static let notchSideHorizontalInset: CGFloat = 8

    static func size(forScreenWidth screenWidth: CGFloat) -> CGSize {
        CGSize(
            width: min(defaultSize.width, max(280, screenWidth - horizontalScreenMargin * 2)),
            height: defaultSize.height
        )
    }

    static func variant(
        for context: MeetingReminderOverlayContext,
        hasNotchGeometry: Bool
    ) -> MeetingReminderOverlayVariant {
        switch context.phase {
        case .idle:
            return .defaultReminder
        case .recording:
            if context.layout == .notchSides, hasNotchGeometry {
                return .notchSidesRecording
            }
            return hasNotchGeometry ? .notchCenterRecording : .centerRecording
        case .processing:
            if context.layout == .notchSides, hasNotchGeometry {
                return .notchSidesProcessing
            }
            return hasNotchGeometry ? .notchCenterProcessing : .centerProcessing
        }
    }

    static func size(
        for variant: MeetingReminderOverlayVariant,
        screenWidth: CGFloat,
        notchSideWidth: CGFloat?
    ) -> CGSize {
        switch variant {
        case .defaultReminder:
            return size(forScreenWidth: screenWidth)
        case .notchSidesRecording, .notchSidesProcessing:
            return CGSize(width: max(280, notchSideWidth ?? defaultSize.width), height: notchSideHeight)
        case .notchCenterRecording, .notchCenterProcessing:
            return CGSize(
                width: min(notchCenterSize.width, max(280, screenWidth - horizontalScreenMargin * 2)),
                height: notchCenterSize.height
            )
        case .centerRecording, .centerProcessing:
            return size(forScreenWidth: screenWidth)
        }
    }

    static func frame(for screen: NSScreen, context: MeetingReminderOverlayContext) -> NSRect {
        let hasNotchGeometry = hasNotchGeometry(for: screen)
        let variant = variant(for: context, hasNotchGeometry: hasNotchGeometry)
        let size = size(
            for: variant,
            screenWidth: screen.frame.width,
            notchSideWidth: notchSideWidth(for: screen)
        )
        return NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    static func hasNotchGeometry(for screen: NSScreen) -> Bool {
        guard screen.safeAreaInsets.top > 0 else { return false }
        guard let leftArea = screen.auxiliaryTopLeftArea,
              let rightArea = screen.auxiliaryTopRightArea else { return false }
        return rightArea.minX > leftArea.maxX
    }

    static func notchSideWidth(for screen: NSScreen) -> CGFloat? {
        guard hasNotchGeometry(for: screen),
              let leftArea = screen.auxiliaryTopLeftArea,
              let rightArea = screen.auxiliaryTopRightArea else { return nil }
        let availableSideWidth = min(leftArea.width, rightArea.width)
        let contentWidth = min(notchSideRegionWidth, max(0, availableSideWidth - notchSideHorizontalInset * 2))
        guard contentWidth >= 64 else { return nil }
        let notchWidth = screen.frame.width - leftArea.width - rightArea.width
        return notchWidth + contentWidth * 2
    }
}

struct MeetingReminderOverlayDisplayData: Equatable {
    let identifier: String
    let title: String
    let startText: String
    let startTimeText: String
    let context: MeetingReminderOverlayContext
    let variant: MeetingReminderOverlayVariant

    var showsStartButton: Bool { variant == .defaultReminder }
}

@MainActor
final class MeetingReminderOverlayManager: CalendarRecordingReminderInAppPresenting {
    private struct QueuedReminder {
        let schedule: CalendarRecordingReminderSchedule
        let onPresented: CalendarRecordingReminderPresentedHandler
    }

    private var panel: NSPanel?
    private var visibleReminder: QueuedReminder?
    private var queue: [QueuedReminder] = []
    private var queuedIdentifiers: Set<String> = []
    private let contextProvider: () -> MeetingReminderOverlayContext

    var onStart: ((CalendarRecordingReminderSchedule) -> Void)?
    var onDismiss: ((CalendarRecordingReminderSchedule) -> Void)?

    init(contextProvider: @escaping () -> MeetingReminderOverlayContext) {
        self.contextProvider = contextProvider
    }

    func presentCalendarRecordingReminder(
        _ schedule: CalendarRecordingReminderSchedule,
        onPresented: @escaping CalendarRecordingReminderPresentedHandler
    ) async -> Bool {
        enqueue(schedule, onPresented: onPresented)
        return true
    }

    func refreshVisibleReminder() {
        guard let visibleReminder else { return }
        render(visibleReminder, markPresented: false, animated: true)
    }

    private func enqueue(_ schedule: CalendarRecordingReminderSchedule, onPresented: @escaping CalendarRecordingReminderPresentedHandler) {
        guard visibleReminder?.schedule.identifier != schedule.identifier,
              !queuedIdentifiers.contains(schedule.identifier) else { return }
        queue.append(QueuedReminder(schedule: schedule, onPresented: onPresented))
        queuedIdentifiers.insert(schedule.identifier)
        showNextIfNeeded()
    }

    private func showNextIfNeeded() {
        guard visibleReminder == nil, !queue.isEmpty else { return }
        let reminder = queue.removeFirst()
        queuedIdentifiers.remove(reminder.schedule.identifier)
        visibleReminder = reminder
        render(reminder, markPresented: true, animated: true)
    }

    private func render(_ reminder: QueuedReminder, markPresented: Bool, animated: Bool) {
        let schedule = reminder.schedule
        guard let screen = NSScreen.main else { return }
        let context = contextProvider()
        let frame = MeetingReminderOverlayGeometry.frame(for: screen, context: context)
        let variant = MeetingReminderOverlayGeometry.variant(
            for: context,
            hasNotchGeometry: MeetingReminderOverlayGeometry.hasNotchGeometry(for: screen)
        )
        let rootView = MeetingReminderOverlayView(
            displayData: displayData(for: schedule, context: context, variant: variant),
            onStart: { [weak self] in self?.handleStart() },
            onDismiss: { [weak self] in self?.handleDismiss() }
        )
        let hostingView = NSHostingView(rootView: rootView.frame(width: frame.width, height: frame.height))
        hostingView.frame = NSRect(origin: .zero, size: frame.size)

        let panel = panel ?? makePanel(frame: frame)
        panel.ignoresMouseEvents = false
        panel.contentView = hostingView
        panel.level = variant.isRecordingContext ? Self.recordingContextLevel : .screenSaver
        self.panel = panel

        if panel.isVisible, animated {
            NSAnimationContext.runAnimationGroup { animationContext in
                animationContext.duration = 0.18
                animationContext.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.56, 0.64, 1.0)
                panel.animator().setFrame(frame, display: true)
            }
        } else if animated {
            let hiddenFrame = NSRect(x: frame.origin.x, y: screen.frame.maxY, width: frame.width, height: frame.height)
            panel.setFrame(hiddenFrame, display: true)
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { animationContext in
                animationContext.duration = 0.18
                animationContext.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.56, 0.64, 1.0)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }

        if markPresented {
            reminder.onPresented(schedule)
        }
    }

    private static var recordingContextLevel: NSWindow.Level {
        NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
    }

    private func makePanel(frame: NSRect) -> NSPanel {
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        return panel
    }

    private func handleStart() {
        guard let reminder = visibleReminder else { return }
        guard contextProvider().phase == .idle else { return }
        hideVisibleReminder(animated: true) { [weak self] in
            self?.onStart?(reminder.schedule)
            self?.showNextIfNeeded()
        }
    }

    private func handleDismiss() {
        guard let reminder = visibleReminder else { return }
        hideVisibleReminder(animated: true) { [weak self] in
            self?.onDismiss?(reminder.schedule)
            self?.showNextIfNeeded()
        }
    }

    private func hideVisibleReminder(animated: Bool, completion: @escaping () -> Void) {
        visibleReminder = nil
        guard let panel, panel.isVisible, let screen = NSScreen.main else {
            panel?.orderOut(nil)
            completion()
            return
        }
        let currentFrame = panel.frame
        let hiddenFrame = NSRect(x: currentFrame.origin.x, y: screen.frame.maxY, width: currentFrame.width, height: currentFrame.height)
        guard animated else {
            panel.orderOut(nil)
            completion()
            return
        }
        NSAnimationContext.runAnimationGroup { animationContext in
            animationContext.duration = 0.14
            animationContext.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(hiddenFrame, display: true)
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
            panel.alphaValue = 1
            completion()
        }
    }

    private func displayData(
        for schedule: CalendarRecordingReminderSchedule,
        context: MeetingReminderOverlayContext,
        variant: MeetingReminderOverlayVariant
    ) -> MeetingReminderOverlayDisplayData {
        MeetingReminderOverlayDisplayData(
            identifier: schedule.identifier,
            title: schedule.event.title,
            startText: Self.startText(for: schedule.event.start),
            startTimeText: Self.startTimeText(for: schedule.event.start),
            context: context,
            variant: variant
        )
    }

    private static func startText(for start: Date) -> String {
        "Starts at \(startTimeText(for: start))"
    }

    private static func startTimeText(for start: Date) -> String {
        DateFormatter.localizedString(from: start, dateStyle: .none, timeStyle: .short)
    }
}

private struct MeetingReminderOverlayView: View {
    let displayData: MeetingReminderOverlayDisplayData
    let onStart: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        switch displayData.variant {
        case .defaultReminder:
            DefaultMeetingReminderOverlayView(displayData: displayData, onStart: onStart, onDismiss: onDismiss)
        case .notchSidesRecording, .notchSidesProcessing:
            NotchSidesMeetingReminderOverlayView(displayData: displayData, onDismiss: onDismiss)
        case .notchCenterRecording, .notchCenterProcessing:
            CenterMeetingReminderOverlayView(
                displayData: displayData,
                topContentHeight: 62,
                appIconX: 56,
                closeButtonX: 56,
                rowTop: 76,
                onDismiss: onDismiss
            )
        case .centerRecording, .centerProcessing:
            CenterMeetingReminderOverlayView(
                displayData: displayData,
                topContentHeight: 38,
                appIconX: 54,
                closeButtonX: 54,
                rowTop: 58,
                onDismiss: onDismiss
            )
        }
    }
}

private struct DefaultMeetingReminderOverlayView: View {
    let displayData: MeetingReminderOverlayDisplayData
    let onStart: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            OverlayBackground(cornerRadius: 26)
            VStack(spacing: 0) {
                HStack {
                    HStack(spacing: 7) {
                        AppIconView(size: 20, cornerRadius: 6)
                        Text("Quill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white.opacity(0.76))
                    }
                    Spacer()
                    CloseButton(action: onDismiss)
                }
                .frame(height: 30)
                .padding(.horizontal, 14)

                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(displayData.title)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(displayData.startText)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.64))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                    Button("Start", action: onStart)
                        .buttonStyle(MeetingReminderPrimaryButtonStyle())
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
                Spacer(minLength: 0)
            }
        }
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 26, bottomTrailingRadius: 26))
    }
}

private struct NotchSidesMeetingReminderOverlayView: View {
    let displayData: MeetingReminderOverlayDisplayData
    let onDismiss: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            OverlayBackground(cornerRadius: 12)
            MeetingInfoRow(
                displayData: displayData,
                includesIcon: true,
                onDismiss: onDismiss
            )
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .padding(.top, 50)
        }
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12))
    }
}

private struct CenterMeetingReminderOverlayView: View {
    let displayData: MeetingReminderOverlayDisplayData
    let topContentHeight: CGFloat
    let appIconX: CGFloat
    let closeButtonX: CGFloat
    let rowTop: CGFloat
    let onDismiss: () -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                OverlayBackground(cornerRadius: displayData.variant == .centerRecording || displayData.variant == .centerProcessing ? 22 : 24)
                AppIconView(size: 22, cornerRadius: 6)
                    .position(x: appIconX + 11, y: topContentHeight / 2)
                CloseButton(action: onDismiss)
                    .position(x: proxy.size.width - closeButtonX + 10, y: topContentHeight / 2)
                MeetingInfoRow(
                    displayData: displayData,
                    includesIcon: false,
                    onDismiss: onDismiss
                )
                .padding(.horizontal, 16)
                .padding(.top, rowTop)
            }
        }
        .clipShape(UnevenRoundedRectangle(
            bottomLeadingRadius: displayData.variant == .centerRecording || displayData.variant == .centerProcessing ? 22 : 24,
            bottomTrailingRadius: displayData.variant == .centerRecording || displayData.variant == .centerProcessing ? 22 : 24
        ))
    }
}

private struct MeetingInfoRow: View {
    let displayData: MeetingReminderOverlayDisplayData
    let includesIcon: Bool
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if includesIcon {
                AppIconView(size: 18, cornerRadius: 5)
            }
            Text(displayData.title)
                .font(.system(size: includesIcon ? 13 : 14, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            Text(displayData.startText)
                .font(.system(size: includesIcon ? 10 : 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.62))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            if includesIcon {
                CloseButton(action: onDismiss)
            }
        }
    }
}

private struct OverlayBackground: View {
    let cornerRadius: CGFloat

    var body: some View {
        Color.black.opacity(0.98)
            .clipShape(UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: cornerRadius,
                bottomTrailingRadius: cornerRadius,
                topTrailingRadius: 0,
                style: .continuous
            ))
    }
}

private struct AppIconView: View {
    let size: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(.white.opacity(0.16), lineWidth: 1)
            )
    }
}

private struct CloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.78))
                .frame(width: 20, height: 20)
                .background(Color.white.opacity(0.10), in: Circle())
        }
        .buttonStyle(.plain)
    }
}

private struct MeetingReminderPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(Color.black)
            .frame(width: 76, height: 30)
            .background(Color.white, in: Capsule())
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}
