import Combine
import SwiftUI

/// Calendar choice for one audio import: the file's recording time, the
/// shown day, and that day's events. Events live only while the sheet is
/// open.
@MainActor
final class AudioImportCalendarModel: ObservableObject {
    @Published var recordingTime: AudioFileRecordingTime?
    @Published private(set) var hasReadRecordingTime = false
    @Published var day = Date()
    @Published private(set) var events: [CalendarEvent] = []
    @Published private(set) var recommendedID: String?
    /// `nil` means "No event".
    @Published var selectedEventID: String?
    @Published private(set) var isLoading = true
    @Published private(set) var googleFailed = false
    @Published private(set) var hasReadableSource = true
    private var loadGeneration = 0
    private var dayChosenByUser = false
    private var eventChosenByUser = false

    var selectedEvent: CalendarEvent? {
        selectedEventID.flatMap { id in events.first { $0.id == id } }
    }

    func start(fileURL: URL, appState: AppState) {
        Task {
            let accessGranted = fileURL.startAccessingSecurityScopedResource()
            let time = await AudioFileRecordingTime.read(from: fileURL)
            if accessGranted { fileURL.stopAccessingSecurityScopedResource() }
            recordingTime = time
            hasReadRecordingTime = true
            applyRecordingDay(time, appState: appState)
        }
    }

    /// A late metadata read must not move a date the person already picked.
    private func applyRecordingDay(_ time: AudioFileRecordingTime?, appState: AppState) {
        guard !dayChosenByUser else {
            load(appState: appState)
            return
        }
        if let time { day = time.start }
        load(appState: appState)
    }

    func pickDay(_ newDay: Date, appState: AppState) {
        dayChosenByUser = true
        day = newDay
        load(appState: appState)
    }

    func pickEvent(_ id: String?) {
        eventChosenByUser = true
        selectedEventID = id
    }

    func load(appState: AppState) {
        loadGeneration += 1
        let generation = loadGeneration
        let shownDay = day
        isLoading = true
        Task {
            let result = await appState.calendarDayEvents(on: shownDay)
            guard generation == loadGeneration else { return }
            events = result.events
            googleFailed = result.googleFailed
            hasReadableSource = result.hasReadableSource
            let recommended = CalendarDayEvents.recommendation(in: result.events, recording: recordingTime)
            recommendedID = recommended?.id
            selectedEventID = ImportCalendarSelection.next(
                current: selectedEventID,
                userChose: eventChosenByUser,
                events: result.events,
                recommendedID: recommended?.id
            )
            isLoading = false
        }
    }

    /// "10월 7일 (화) 오후 2:02~2:46", or the no-time hint.
    var headerDetail: String? {
        guard hasReadRecordingTime else { return nil }
        guard let recordingTime else {
            return localizedCatalogString("No recording time in this file; choose the date")
        }
        return Self.rangeText(recordingTime.start, recordingTime.end)
    }

    static func rangeText(_ start: Date, _ end: Date) -> String {
        let formatter = DateIntervalFormatter()
        formatter.dateTemplate = "MMMdEEEjm"
        return formatter.string(from: start, to: end)
    }
}

struct AudioImportCalendarSection: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var model: AudioImportCalendarModel
    @State private var showsDatePicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Calendar Event")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            if !model.hasReadableSource {
                Text("Connect a calendar to add the meeting title and attendees.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Calendar Settings…") {
                    appState.openCalendarSettings()
                }
            } else {
                dateButton
                if model.isLoading {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Loading events…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    eventList
                }
                if model.googleFailed {
                    Text("Some calendars couldn't be loaded.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        // Reload after Calendar Settings… connects, reconnects, grants access,
        // or changes which calendars are selected.
        .onReceive(
            appState.$googleCalendarConnection
                .map { "\($0.isConnected)|\($0.selectedCalendarIDs.sorted())" }
                .removeDuplicates()
                .dropFirst()
        ) { _ in
            model.load(appState: appState)
        }
        .onReceive(appState.$appleCalendarSelectedIDs.removeDuplicates().dropFirst()) { _ in
            model.load(appState: appState)
        }
        .onReceive(appState.$appleCalendarAuthorization.removeDuplicates().dropFirst()) { _ in
            model.load(appState: appState)
        }
        .onReceive(appState.$appleCalendarEnabled.removeDuplicates().dropFirst()) { _ in
            model.load(appState: appState)
        }
    }

    private var dateButton: some View {
        Button {
            showsDatePicker.toggle()
        } label: {
            HStack(spacing: 4) {
                Text(model.day.formatted(.dateTime.month().day().weekday(.abbreviated)))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
        }
        .popover(isPresented: $showsDatePicker, arrowEdge: .bottom) {
            DatePicker(
                "",
                selection: Binding(
                    get: { model.day },
                    set: { newDay in
                        showsDatePicker = false
                        model.pickDay(newDay, appState: appState)
                    }
                ),
                displayedComponents: .date
            )
                .datePickerStyle(.graphical)
                .labelsHidden()
                .padding(12)
        }
    }

    private var eventList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.events) { event in
                row(
                    isSelected: model.selectedEventID == event.id,
                    title: event.title,
                    isSuggested: event.id == model.recommendedID,
                    detail: detail(for: event)
                ) {
                    model.pickEvent(event.id)
                }
            }
            row(
                isSelected: model.selectedEventID == nil,
                title: localizedCatalogString("No event"),
                isSuggested: false,
                detail: localizedCatalogString("The title comes from the first line of the transcript")
            ) {
                model.pickEvent(nil)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }

    private func detail(for event: CalendarEvent) -> String {
        var parts = [
            "\(event.start.formatted(date: .omitted, time: .shortened))~\(event.end.formatted(date: .omitted, time: .shortened))",
            event.provider == .google ? "Google" : "Apple"
        ]
        if !event.attendees.isEmpty {
            parts.append(localizedCatalogFormat("%lld attendees", Int64(event.attendees.count)))
        }
        if event.id == model.recommendedID {
            parts.append(localizedCatalogFormat(
                "Title: %@",
                ImportCalendarTitle.title(for: event, recording: model.recordingTime, chosenDay: model.day)
            ))
        }
        return parts.joined(separator: " · ")
    }

    private func row(
        isSelected: Bool,
        title: String,
        isSuggested: Bool,
        detail: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(verbatim: title)
                        if isSuggested {
                            Text("Suggested")
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.15), in: Capsule())
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    Text(verbatim: detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
