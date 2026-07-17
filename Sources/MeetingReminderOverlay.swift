import AppKit
import Combine
import SwiftUI

private let meetingReminderPanelResizeDuration: TimeInterval = 0.28
private let meetingReminderContentTransitionAnimation = Animation.spring(response: meetingReminderPanelResizeDuration, dampingFraction: 0.88, blendDuration: 0.08)

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
    static let notchCenterSize = CGSize(width: 360, height: 112)

    private static let notchSideRegionWidth: CGFloat = 92
    private static let notchSideHorizontalInset: CGFloat = 8
    private static let centerRecordingBaseWidth: CGFloat = 150

    /// Shared height for the centered reminder card. The idle (default) reminder
    /// and the recording/processing banner use the same height so the card morphs
    /// smoothly between them when recording starts from a visible reminder.
    static let centerReminderCardHeight: CGFloat = 80
    /// Approximate height of the single-line meeting-info row, used to vertically
    /// center it in the content area below the top strip.
    private static let centerRecordingRowHeight: CGFloat = 20

    /// Top inset that vertically centers the single-line meeting-info row in the
    /// content area below the top strip (which tracks the recording pill height).
    static func centerRecordingRowTop(stripHeight: CGFloat) -> CGFloat {
        let contentArea = centerReminderCardHeight - stripHeight
        return stripHeight + max(0, (contentArea - centerRecordingRowHeight) / 2)
    }

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
            let width = size(forScreenWidth: screenWidth).width
            let resolvedWidth = notchSideWidth.map { max(width, $0) } ?? width
            return CGSize(width: resolvedWidth, height: centerReminderCardHeight)
        case .notchSidesRecording, .notchSidesProcessing:
            return CGSize(width: max(280, notchSideWidth ?? defaultSize.width), height: defaultSize.height)
        case .notchCenterRecording, .notchCenterProcessing:
            let width = max(notchCenterSize.width, notchSideWidth ?? 0)
            return CGSize(
                width: min(width, max(280, screenWidth - horizontalScreenMargin * 2)),
                height: notchCenterSize.height
            )
        case .centerRecording, .centerProcessing:
            // Matches the idle reminder height so the two morph smoothly; the top
            // strip aligns with the recording pill and the meeting row is centered
            // in the area below it.
            return CGSize(
                width: size(forScreenWidth: screenWidth).width,
                height: centerReminderCardHeight
            )
        }
    }

    static func frame(for screen: NSScreen, context: MeetingReminderOverlayContext) -> NSRect {
        frame(for: OverlayScreenGeometry(screen: screen), context: context)
    }

    static func frame(for geometry: OverlayScreenGeometry, context: MeetingReminderOverlayContext) -> NSRect {
        let variant = variant(for: context, hasNotchGeometry: hasNotchGeometry(for: geometry))
        let size = size(
            for: variant,
            screenWidth: geometry.screenFrame.width,
            notchSideWidth: notchSideWidth(for: geometry)
        )
        if (variant == .notchSidesRecording || variant == .notchSidesProcessing),
           let notchSideGeometry = geometry.notchSideGeometry(
               regionWidth: notchSideRegionWidth,
               panelHeight: size.height,
               horizontalInset: notchSideHorizontalInset
           ) {
            return notchSideGeometry.frame
        }
        return geometry.centeredTopFrame(width: size.width, height: size.height)
    }

    static func hasNotchGeometry(for screen: NSScreen) -> Bool {
        hasNotchGeometry(for: OverlayScreenGeometry(screen: screen))
    }

    static func hasNotchGeometry(for geometry: OverlayScreenGeometry) -> Bool {
        geometry.hasNotchGeometry
    }

    static func notchSideWidth(for screen: NSScreen) -> CGFloat? {
        notchSideWidth(for: OverlayScreenGeometry(screen: screen))
    }

    static func notchSideWidth(for geometry: OverlayScreenGeometry) -> CGFloat? {
        geometry.notchSideGeometry(
            regionWidth: notchSideRegionWidth,
            panelHeight: defaultSize.height,
            horizontalInset: notchSideHorizontalInset
        )?.frame.width
    }

    static func centerRecordingOverlayWidth(for screen: NSScreen) -> CGFloat {
        centerRecordingOverlayWidth(for: OverlayScreenGeometry(screen: screen))
    }

    static func centerRecordingOverlayWidth(for geometry: OverlayScreenGeometry) -> CGFloat {
        guard let notchWidth = geometry.notchWidth else { return centerRecordingBaseWidth }
        return max(notchWidth, centerRecordingBaseWidth)
    }
}

struct MeetingReminderOverlayDisplayData: Equatable {
    let identifier: String
    let title: String
    let startText: String
    let startTimeText: String
    let context: MeetingReminderOverlayContext
    let variant: MeetingReminderOverlayVariant
    let centerOverlayWidth: CGFloat
    /// Height of the top strip in the center recording/processing variants,
    /// matched to the recording pill height so the two align.
    let topStripHeight: CGFloat

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
    private var contentContainer: FixedHostingContainer<AnyView>?
    private var isHidingVisibleReminder = false
    private var visibleReminder: QueuedReminder?
    private var queue: [QueuedReminder] = []
    private var queuedIdentifiers: Set<String> = []
    private var queuedReminderGroupIdentifiers: Set<String> = []
    private let contextProvider: () -> MeetingReminderOverlayContext
    private let screenProvider: () -> NSScreen?
    private var screenParametersObserver: NSObjectProtocol?

    var onStart: (@MainActor (CalendarRecordingReminderSchedule) -> Void)?
    var onDismiss: (@MainActor (CalendarRecordingReminderSchedule) -> Void)?

    /// Frame of the reminder panel while a reminder is actually visible, else
    /// nil. Lets the recording overlay anchor a notice toast below the card.
    var visibleOverlayFrame: NSRect? {
        guard visibleReminder != nil, let panel, panel.isVisible, panel.alphaValue > 0 else { return nil }
        return panel.frame
    }

    init(
        contextProvider: @escaping () -> MeetingReminderOverlayContext,
        screenProvider: @escaping () -> NSScreen? = { NSScreen.main }
    ) {
        self.contextProvider = contextProvider
        self.screenProvider = screenProvider
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleScreenParametersChanged()
            }
        }
    }

    deinit {
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
        }
    }

    func presentCalendarRecordingReminder(
        _ schedule: CalendarRecordingReminderSchedule,
        onPresented: @escaping CalendarRecordingReminderPresentedHandler
    ) async -> Bool {
        enqueue(schedule, onPresented: onPresented)
    }

    func refreshVisibleReminder() {
        refreshVisibleReminder(animated: true)
    }

    private func refreshVisibleReminder(animated: Bool) {
        guard let visibleReminder else { return }
        _ = render(visibleReminder, markPresented: false, animated: animated)
    }

    private func handleScreenParametersChanged() {
        refreshVisibleReminder(animated: false)
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
        guard !isHidingVisibleReminder, visibleReminder == nil, !queue.isEmpty else { return true }
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
        let geometry = OverlayScreenGeometry(screen: screen)
        let frame = MeetingReminderOverlayGeometry.frame(for: geometry, context: context)
        let variant = MeetingReminderOverlayGeometry.variant(
            for: context,
            hasNotchGeometry: MeetingReminderOverlayGeometry.hasNotchGeometry(for: geometry)
        )
        let displayData = displayData(
            for: schedule,
            context: context,
            variant: variant,
            centerOverlayWidth: MeetingReminderOverlayGeometry.centerRecordingOverlayWidth(for: geometry),
            topStripHeight: geometry.menuBarStripHeight
        )

        if let panel, let viewModel, let contentContainer {
            updateExistingPresentation(
                panel: panel,
                viewModel: viewModel,
                contentContainer: contentContainer,
                displayData: displayData,
                frame: frame,
                animated: animated
            )
        } else {
            let viewModel = MeetingReminderOverlayViewModel(displayData: displayData, frameSize: frame.size)
            let container = makeContentContainer(viewModel: viewModel, frame: frame)
            let panel = panel ?? makePanel(frame: frame)
            panel.contentView = container
            self.viewModel = viewModel
            self.contentContainer = container
            self.panel = panel
            presentNewPanel(panel, frame: frame, screen: screen, animated: animated)
        }

        panel?.ignoresMouseEvents = false
        panel?.level = variant.isRecordingContext ? Self.recordingContextLevel : .screenSaver

        if markPresented {
            reminder.onPresented(schedule)
        }
        return true
    }

    private func makeContentContainer(
        viewModel: MeetingReminderOverlayViewModel,
        frame: NSRect
    ) -> FixedHostingContainer<AnyView> {
        let rootView = MeetingReminderOverlayRootView(
            viewModel: viewModel,
            onStart: { [weak self] in self?.handleStart() },
            onDismiss: { [weak self] in self?.handleDismiss() }
        )
        let container = FixedHostingContainer(
            rootView: AnyView(rootView),
            size: frame.size
        )
        container.autoresizingMask = [.width, .height]
        return container
    }

    private func updateExistingPresentation(
        panel: NSPanel,
        viewModel: MeetingReminderOverlayViewModel,
        contentContainer: FixedHostingContainer<AnyView>,
        displayData: MeetingReminderOverlayDisplayData,
        frame: NSRect,
        animated: Bool
    ) {
        contentContainer.setFixedContentSize(frame.size)
        viewModel.update(displayData: displayData, frameSize: frame.size, animated: animated)
        resize(panel: panel, to: frame, animated: animated)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    private func presentNewPanel(
        _ panel: NSPanel,
        frame: NSRect,
        screen: NSScreen,
        animated: Bool
    ) {
        guard animated else {
            panel.setFrame(frame, display: true)
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            return
        }

        let hiddenFrame = NSRect(x: frame.origin.x, y: screen.frame.maxY, width: frame.width, height: frame.height)
        panel.setFrame(hiddenFrame, display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { animationContext in
            animationContext.duration = meetingReminderPanelResizeDuration
            animationContext.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.56, 0.64, 1.0)
            panel.animator().setFrame(frame, display: true)
        }
    }

    private func resize(panel: NSPanel, to frame: NSRect, animated: Bool) {
        guard animated else {
            panel.setFrame(frame, display: true)
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            return
        }

        NSAnimationContext.runAnimationGroup { animationContext in
            animationContext.duration = meetingReminderPanelResizeDuration
            animationContext.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.56, 0.64, 1.0)
            panel.animator().setFrame(frame, display: true)
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
        isHidingVisibleReminder = true
        guard let panel, panel.isVisible, let screen = panel.screen ?? screenProvider() ?? NSScreen.main else {
            panel?.orderOut(nil)
            resetPresentationHost()
            isHidingVisibleReminder = false
            completion()
            _ = showNextIfNeeded()
            return
        }
        let currentFrame = panel.frame
        let hiddenFrame = NSRect(x: currentFrame.origin.x, y: screen.frame.maxY, width: currentFrame.width, height: currentFrame.height)
        guard animated else {
            panel.orderOut(nil)
            resetPresentationHost()
            isHidingVisibleReminder = false
            completion()
            _ = showNextIfNeeded()
            return
        }
        NSAnimationContext.runAnimationGroup { animationContext in
            animationContext.duration = 0.14
            animationContext.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(hiddenFrame, display: true)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            panel.orderOut(nil)
            panel.alphaValue = 1
            MainActor.assumeIsolated {
                self?.resetPresentationHost()
                self?.isHidingVisibleReminder = false
                completion()
                _ = self?.showNextIfNeeded()
            }
        }
    }

    private func resetPresentationHost() {
        if let panel {
            panel.contentView = nil
        }
        panel = nil
        viewModel = nil
        contentContainer = nil
    }

    private func displayData(
        for schedule: CalendarRecordingReminderSchedule,
        context: MeetingReminderOverlayContext,
        variant: MeetingReminderOverlayVariant,
        centerOverlayWidth: CGFloat,
        topStripHeight: CGFloat
    ) -> MeetingReminderOverlayDisplayData {
        MeetingReminderOverlayDisplayData(
            identifier: schedule.identifier,
            title: schedule.event.title,
            startText: Self.startText(for: schedule.event.start),
            startTimeText: Self.startTimeText(for: schedule.event.start),
            context: context,
            variant: variant,
            centerOverlayWidth: centerOverlayWidth,
            topStripHeight: topStripHeight
        )
    }

    private static func startText(for start: Date) -> String {
        OverlayDisplayCopy.meetingStarts(at: startTimeText(for: start))
    }

    private static func startTimeText(for start: Date) -> String {
        DateFormatter.localizedString(from: start, dateStyle: .none, timeStyle: .short)
    }
}

@MainActor
private final class MeetingReminderOverlayViewModel: ObservableObject {
    @Published var displayData: MeetingReminderOverlayDisplayData
    @Published var frameSize: CGSize

    init(displayData: MeetingReminderOverlayDisplayData, frameSize: CGSize) {
        self.displayData = displayData
        self.frameSize = frameSize
    }

    func update(displayData: MeetingReminderOverlayDisplayData, frameSize: CGSize, animated: Bool) {
        if animated {
            withAnimation(meetingReminderContentTransitionAnimation) {
                self.displayData = displayData
                self.frameSize = frameSize
            }
        } else {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                self.displayData = displayData
                self.frameSize = frameSize
            }
        }
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
        .frame(width: viewModel.frameSize.width, height: viewModel.frameSize.height)
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
                topContentHeight: 77,
                rowTop: 76,
                onDismiss: onDismiss
            )
        case .centerRecording, .centerProcessing:
            CenterMeetingReminderOverlayView(
                displayData: displayData,
                animationNamespace: animationNamespace,
                topContentHeight: displayData.topStripHeight,
                rowTop: MeetingReminderOverlayGeometry.centerRecordingRowTop(stripHeight: displayData.topStripHeight),
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
                    let topSideAreaWidth = max(0, (proxy.size.width - displayData.centerOverlayWidth) / 2)
                    ZStack(alignment: .topLeading) {
                        HStack(spacing: 6) {
                            AppIconView(size: 22, cornerRadius: 6)
                                .matchedGeometryEffect(id: "appIcon", in: animationNamespace)
                            Text(verbatim: "Quill")
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
            let topSideAreaWidth = max(0, (proxy.size.width - displayData.centerOverlayWidth) / 2)
            ZStack(alignment: .topLeading) {
                OverlayBackground(cornerRadius: displayData.variant == .centerRecording || displayData.variant == .centerProcessing ? 22 : 24)
                    .matchedGeometryEffect(id: "background", in: animationNamespace)
                HStack(spacing: 6) {
                    AppIconView(size: 22, cornerRadius: 6)
                        .matchedGeometryEffect(id: "appIcon", in: animationNamespace)
                    Text(verbatim: "Quill")
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
        .accessibilityLabel("Close")
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
