import AppKit
import Combine
import SwiftUI

private let meetingReminderContentTransitionAnimation = Animation.spring(response: 0.28, dampingFraction: 0.88, blendDuration: 0.08)
private let meetingReminderCenterOverlayWidth: CGFloat = 150

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
            return CGSize(width: max(280, notchSideWidth ?? defaultSize.width), height: defaultSize.height)
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
    private var viewModel: MeetingReminderOverlayViewModel?
    private var visibleReminder: QueuedReminder?
    private var queue: [QueuedReminder] = []
    private var queuedIdentifiers: Set<String> = []
    private var queuedReminderGroupIdentifiers: Set<String> = []
    private let contextProvider: () -> MeetingReminderOverlayContext
    private let screenProvider: () -> NSScreen?

    var onStart: (@MainActor (CalendarRecordingReminderSchedule) -> Void)?
    var onDismiss: (@MainActor (CalendarRecordingReminderSchedule) -> Void)?

    init(
        contextProvider: @escaping () -> MeetingReminderOverlayContext,
        screenProvider: @escaping () -> NSScreen? = { NSScreen.main }
    ) {
        self.contextProvider = contextProvider
        self.screenProvider = screenProvider
    }

    func presentCalendarRecordingReminder(
        _ schedule: CalendarRecordingReminderSchedule,
        onPresented: @escaping CalendarRecordingReminderPresentedHandler
    ) async -> Bool {
        enqueue(schedule, onPresented: onPresented)
    }

    func refreshVisibleReminder() {
        guard let visibleReminder else { return }
        _ = render(visibleReminder, markPresented: false, animated: true)
    }

    private func enqueue(_ schedule: CalendarRecordingReminderSchedule, onPresented: @escaping CalendarRecordingReminderPresentedHandler) -> Bool {
        if visibleReminder?.schedule.reminderGroupIdentifier == schedule.reminderGroupIdentifier || queuedReminderGroupIdentifiers.contains(schedule.reminderGroupIdentifier) {
            onPresented(schedule)
            return true
        }
        guard !queuedIdentifiers.contains(schedule.identifier) else { return true }
        guard screenProvider() != nil else { return false }
        queue.append(QueuedReminder(schedule: schedule, onPresented: onPresented))
        queuedIdentifiers.insert(schedule.identifier)
        queuedReminderGroupIdentifiers.insert(schedule.reminderGroupIdentifier)
        return showNextIfNeeded()
    }

    private func showNextIfNeeded() -> Bool {
        guard visibleReminder == nil, !queue.isEmpty else { return true }
        let reminder = queue.removeFirst()
        queuedIdentifiers.remove(reminder.schedule.identifier)
        queuedReminderGroupIdentifiers.remove(reminder.schedule.reminderGroupIdentifier)
        visibleReminder = reminder
        if render(reminder, markPresented: true, animated: true) {
            return true
        }
        visibleReminder = nil
        return false
    }

    private func render(_ reminder: QueuedReminder, markPresented: Bool, animated: Bool) -> Bool {
        let schedule = reminder.schedule
        guard let screen = screenProvider() else { return false }
        let context = contextProvider()
        let frame = MeetingReminderOverlayGeometry.frame(for: screen, context: context)
        let variant = MeetingReminderOverlayGeometry.variant(
            for: context,
            hasNotchGeometry: MeetingReminderOverlayGeometry.hasNotchGeometry(for: screen)
        )
        let displayData = displayData(for: schedule, context: context, variant: variant)
        let panel = panel ?? makePanel(frame: frame)
        panel.ignoresMouseEvents = false
        if let viewModel, panel.contentView != nil {
            withAnimation(meetingReminderContentTransitionAnimation) {
                viewModel.displayData = displayData
            }
            panel.contentView?.frame = NSRect(origin: .zero, size: frame.size)
        } else {
            let viewModel = MeetingReminderOverlayViewModel(displayData: displayData)
            let hostingView = NSHostingView(rootView: MeetingReminderOverlayRootView(
                viewModel: viewModel,
                onStart: { [weak self] in self?.handleStart() },
                onDismiss: { [weak self] in self?.handleDismiss() }
            ))
            hostingView.frame = NSRect(origin: .zero, size: frame.size)
            panel.contentView = hostingView
            self.viewModel = viewModel
        }
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
        return true
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
            _ = self?.showNextIfNeeded()
        }
    }

    private func handleDismiss() {
        guard let reminder = visibleReminder else { return }
        hideVisibleReminder(animated: true) { [weak self] in
            self?.onDismiss?(reminder.schedule)
            _ = self?.showNextIfNeeded()
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

@MainActor
private final class MeetingReminderOverlayViewModel: ObservableObject {
    @Published var displayData: MeetingReminderOverlayDisplayData

    init(displayData: MeetingReminderOverlayDisplayData) {
        self.displayData = displayData
    }
}

private struct MeetingReminderOverlayRootView: View {
    @ObservedObject var viewModel: MeetingReminderOverlayViewModel
    let onStart: () -> Void
    let onDismiss: () -> Void
    @Namespace private var animationNamespace

    var body: some View {
        MeetingReminderOverlayView(
            displayData: viewModel.displayData,
            animationNamespace: animationNamespace,
            onStart: onStart,
            onDismiss: onDismiss
        )
        .animation(meetingReminderContentTransitionAnimation, value: viewModel.displayData)
    }
}

private struct MeetingReminderOverlayView: View {
    let displayData: MeetingReminderOverlayDisplayData
    let animationNamespace: Namespace.ID
    let onStart: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        switch displayData.variant {
        case .defaultReminder:
            DefaultMeetingReminderOverlayView(
                displayData: displayData,
                animationNamespace: animationNamespace,
                onStart: onStart,
                onDismiss: onDismiss
            )
        case .notchSidesRecording, .notchSidesProcessing:
            NotchSidesMeetingReminderOverlayView(
                displayData: displayData,
                animationNamespace: animationNamespace,
                onDismiss: onDismiss
            )
        case .notchCenterRecording, .notchCenterProcessing:
            CenterMeetingReminderOverlayView(
                displayData: displayData,
                animationNamespace: animationNamespace,
                topContentHeight: 62,
                rowTop: 76,
                onDismiss: onDismiss
            )
        case .centerRecording, .centerProcessing:
            CenterMeetingReminderOverlayView(
                displayData: displayData,
                animationNamespace: animationNamespace,
                topContentHeight: 38,
                rowTop: 58,
                onDismiss: onDismiss
            )
        }
    }
}

private struct DefaultMeetingReminderOverlayView: View {
    let displayData: MeetingReminderOverlayDisplayData
    let animationNamespace: Namespace.ID
    let onStart: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            OverlayBackground(cornerRadius: 26)
                .matchedGeometryEffect(id: "background", in: animationNamespace)
            VStack(spacing: 0) {
                GeometryReader { proxy in
                    let topSideAreaWidth = max(0, (proxy.size.width - meetingReminderCenterOverlayWidth) / 2)
                    ZStack(alignment: .topLeading) {
                        HStack(spacing: 6) {
                            AppIconView(size: 22, cornerRadius: 6)
                                .matchedGeometryEffect(id: "appIcon", in: animationNamespace)
                            Text("Quill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white.opacity(0.72))
                                .lineLimit(1)
                                .matchedGeometryEffect(id: "appName", in: animationNamespace, properties: .position)
                        }
                        .frame(width: topSideAreaWidth, height: 30)
                        .position(x: topSideAreaWidth / 2, y: 15)
                        CloseButton(action: onDismiss)
                            .matchedGeometryEffect(id: "closeButton", in: animationNamespace)
                            .frame(width: topSideAreaWidth, height: 30)
                            .position(x: proxy.size.width - topSideAreaWidth / 2, y: 15)
                    }
                }
                .frame(height: 30)

                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(displayData.title)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .matchedGeometryEffect(id: "title", in: animationNamespace, properties: .position)
                        Text(displayData.startText)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.62))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .matchedGeometryEffect(id: "startText", in: animationNamespace, properties: .position)
                    }
                    Spacer(minLength: 0)
                    Button("Start", action: onStart)
                        .buttonStyle(MeetingReminderPrimaryButtonStyle())
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
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
    let animationNamespace: Namespace.ID
    let onDismiss: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            OverlayBackground(cornerRadius: 26)
                .matchedGeometryEffect(id: "background", in: animationNamespace)
            MeetingInfoRow(
                displayData: displayData,
                includesIcon: true,
                animationNamespace: animationNamespace,
                onDismiss: onDismiss
            )
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .padding(.top, 50)
        }
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 26, bottomTrailingRadius: 26))
    }
}

private struct CenterMeetingReminderOverlayView: View {
    let displayData: MeetingReminderOverlayDisplayData
    let animationNamespace: Namespace.ID
    let topContentHeight: CGFloat
    let rowTop: CGFloat
    let onDismiss: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let topSideAreaWidth = max(0, (proxy.size.width - meetingReminderCenterOverlayWidth) / 2)
            ZStack(alignment: .topLeading) {
                OverlayBackground(cornerRadius: displayData.variant == .centerRecording || displayData.variant == .centerProcessing ? 22 : 24)
                    .matchedGeometryEffect(id: "background", in: animationNamespace)
                HStack(spacing: 6) {
                    AppIconView(size: 22, cornerRadius: 6)
                        .matchedGeometryEffect(id: "appIcon", in: animationNamespace)
                    Text("Quill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                        .matchedGeometryEffect(id: "appName", in: animationNamespace, properties: .position)
                }
                .frame(width: topSideAreaWidth, height: topContentHeight)
                .position(x: topSideAreaWidth / 2, y: topContentHeight / 2)
                CloseButton(action: onDismiss)
                    .matchedGeometryEffect(id: "closeButton", in: animationNamespace)
                    .frame(width: topSideAreaWidth, height: topContentHeight)
                    .position(x: proxy.size.width - topSideAreaWidth / 2, y: topContentHeight / 2)
                MeetingInfoRow(
                    displayData: displayData,
                    includesIcon: false,
                    animationNamespace: animationNamespace,
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
    let animationNamespace: Namespace.ID
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if includesIcon {
                AppIconView(size: 18, cornerRadius: 5)
                    .matchedGeometryEffect(id: "appIcon", in: animationNamespace)
            }
            Text(displayData.title)
                .font(.system(size: includesIcon ? 13 : 14, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .matchedGeometryEffect(id: "title", in: animationNamespace, properties: .position)
            Spacer(minLength: 0)
            Text(displayData.startText)
                .font(.system(size: includesIcon ? 10 : 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.62))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .matchedGeometryEffect(id: "startText", in: animationNamespace, properties: .position)
            if includesIcon {
                CloseButton(action: onDismiss)
                    .matchedGeometryEffect(id: "closeButton", in: animationNamespace)
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
