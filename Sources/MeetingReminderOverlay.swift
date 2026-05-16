import AppKit
import SwiftUI

struct MeetingReminderOverlayGeometry {
    static let defaultSize = CGSize(width: 368, height: 112)
    static let horizontalScreenMargin: CGFloat = 16

    static func size(forScreenWidth screenWidth: CGFloat) -> CGSize {
        CGSize(
            width: min(defaultSize.width, max(280, screenWidth - horizontalScreenMargin * 2)),
            height: defaultSize.height
        )
    }

    static func frame(for screen: NSScreen) -> NSRect {
        let size = size(forScreenWidth: screen.frame.width)
        return NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }
}

struct MeetingReminderOverlayDisplayData: Equatable {
    let identifier: String
    let title: String
    let startText: String
    let isRecording: Bool

    var actionTitle: String { isRecording ? "Recording" : "Start" }
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
    private let isRecordingProvider: () -> Bool

    var onStart: ((CalendarRecordingReminderSchedule) -> Void)?
    var onDismiss: ((CalendarRecordingReminderSchedule) -> Void)?

    init(isRecordingProvider: @escaping () -> Bool) {
        self.isRecordingProvider = isRecordingProvider
    }

    func presentCalendarRecordingReminder(
        _ schedule: CalendarRecordingReminderSchedule,
        onPresented: @escaping CalendarRecordingReminderPresentedHandler
    ) async -> Bool {
        enqueue(schedule, onPresented: onPresented)
        return true
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
        show(reminder)
    }

    private func show(_ reminder: QueuedReminder) {
        let schedule = reminder.schedule
        guard let screen = NSScreen.main else { return }
        let frame = MeetingReminderOverlayGeometry.frame(for: screen)
        let rootView = MeetingReminderOverlayView(
            displayData: displayData(for: schedule),
            onStart: { [weak self] in self?.handleStart() },
            onDismiss: { [weak self] in self?.handleDismiss() }
        )
        let hostingView = NSHostingView(rootView: rootView.frame(width: frame.width, height: frame.height))
        hostingView.frame = NSRect(origin: .zero, size: frame.size)

        let panel = panel ?? makePanel(frame: frame)
        panel.ignoresMouseEvents = false
        panel.contentView = hostingView
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        self.panel = panel
        reminder.onPresented(schedule)
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
        guard let schedule = visibleReminder?.schedule else { return }
        guard !isRecordingProvider() else { return }
        hideVisibleReminder()
        onStart?(schedule)
        showNextIfNeeded()
    }

    private func handleDismiss() {
        guard let schedule = visibleReminder?.schedule else { return }
        hideVisibleReminder()
        onDismiss?(schedule)
        showNextIfNeeded()
    }

    private func hideVisibleReminder() {
        visibleReminder = nil
        panel?.orderOut(nil)
    }

    private func displayData(for schedule: CalendarRecordingReminderSchedule) -> MeetingReminderOverlayDisplayData {
        MeetingReminderOverlayDisplayData(
            identifier: schedule.identifier,
            title: schedule.event.title,
            startText: Self.startText(for: schedule.event.start, now: Date()),
            isRecording: isRecordingProvider()
        )
    }

    private static func startText(for start: Date, now: Date) -> String {
        let time = DateFormatter.localizedString(from: start, dateStyle: .none, timeStyle: .short)
        let minutes = Int(ceil(start.timeIntervalSince(now) / 60))
        if minutes > 1 {
            return "Starts at \(time) · in \(minutes) minutes"
        }
        if minutes == 1 {
            return "Starts at \(time) · in 1 minute"
        }
        return "Starts at \(time) · now"
    }
}

private struct MeetingReminderOverlayView: View {
    let displayData: MeetingReminderOverlayDisplayData
    let onStart: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(Color.black.opacity(0.98))
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Color.black.opacity(0.98))
                        .frame(height: 36)
                }
            VStack(spacing: 0) {
                header
                    .frame(height: 32)
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(displayData.title)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(displayData.startText)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.64))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                    Button(displayData.actionTitle, action: onStart)
                        .buttonStyle(MeetingReminderPrimaryButtonStyle(disabled: displayData.isRecording))
                        .disabled(displayData.isRecording)
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                Spacer(minLength: 0)
            }
        }
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 30, bottomTrailingRadius: 30))
    }

    private var header: some View {
        HStack {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(LinearGradient(colors: [.purple, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 20, height: 20)
                    .overlay(Text("Q").font(.system(size: 10, weight: .bold)).foregroundStyle(.white))
                Text("Quill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.76))
            }
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.78))
                    .frame(width: 22, height: 22)
                    .background(Color.white.opacity(0.10), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
    }
}

private struct MeetingReminderPrimaryButtonStyle: ButtonStyle {
    let disabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(disabled ? .white.opacity(0.65) : Color.black)
            .frame(width: 82, height: 34)
            .background(disabled ? Color.white.opacity(0.12) : Color.white, in: Capsule())
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}
