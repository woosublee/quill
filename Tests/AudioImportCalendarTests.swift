import Foundation

@main
struct AudioImportCalendarTests {
    static func main() async throws {
        testRecordingTimeNeedsEmbeddedDate()
        try await testReadingSyntheticWAVWithoutDateReturnsNil()
        testMeetingCandidatesDropAllDayUntitledDeclinedAndSort()
        testRecommendationPicksLargestOverlapOnly()
        testAppliedTitleUsesRecordingDayOrEventDay()
        testInsertionIndexKeepsNewestFirst()
        testImportSelectionSourceRoundTrips()
        try testAppStateImportWiring()
        try testBrowserFocusesInsertedNote()
        testTitleUsesChosenDayWithoutRecordingTime()
        testSelectionSurvivesReload()
        try testReviewFixesWiring()
        testSelectionKeyIncludesCalendar()
        testRecommendationOnlyOnDaysOverlappingRecording()
        testManualSelectionSurvivesGoogleFailure()
        try testCodeRabbitFixesWiring()
        print("AudioImportCalendarTests passed")
    }

    static let base = Date(timeIntervalSince1970: 1_791_340_000) // fixed synthetic instant

    static func event(_ id: String, _ title: String, _ start: TimeInterval, _ end: TimeInterval, allDay: Bool = false, declined: Bool = false, provider: CalendarProvider = .google) -> CalendarEvent {
        CalendarEvent(id: id, calendarID: "cal", title: title,
                      start: base.addingTimeInterval(start), end: base.addingTimeInterval(end),
                      isAllDay: allDay,
                      attendees: declined ? [CalendarEventAttendee(responseStatus: "declined", isSelf: true)] : [],
                      provider: provider)
    }

    static func testRecordingTimeNeedsEmbeddedDate() {
        precondition(AudioFileRecordingTime.make(creationDate: nil, duration: 60) == nil)
        let time = AudioFileRecordingTime.make(creationDate: base, duration: 2_679.1)
        precondition(time?.start == base && time?.end == base.addingTimeInterval(2_679.1))
        precondition(AudioFileRecordingTime.make(creationDate: base, duration: 0) == nil)
    }

    static func testReadingSyntheticWAVWithoutDateReturnsNil() async throws {
        // 0.1 s of silence, 16-bit mono 16 kHz, written by the test.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("import-calendar-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let samples = 1_600
        var data = Data()
        func append<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + samples * 2).littleEndian)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16).littleEndian)
        append(UInt16(1).littleEndian); append(UInt16(1).littleEndian)
        append(UInt32(16_000).littleEndian); append(UInt32(32_000).littleEndian)
        append(UInt16(2).littleEndian); append(UInt16(16).littleEndian)
        data.append(contentsOf: Array("data".utf8)); append(UInt32(samples * 2).littleEndian)
        data.append(Data(count: samples * 2))
        try data.write(to: url)
        let time = await AudioFileRecordingTime.read(from: url)
        precondition(time == nil, "a file without an embedded creation date has no recording time")
    }

    static func testMeetingCandidatesDropAllDayUntitledDeclinedAndSort() {
        let events = [
            event("late", "1:1", 7_200, 9_000),
            event("allday", "Holiday", 0, 86_400, allDay: true),
            event("untitled", "  ", 100, 200),
            event("declined", "Skip", 300, 600, declined: true),
            event("early", "Standup", 60, 960),
        ]
        precondition(CalendarDayEvents.meetingCandidates(events).map(\.id) == ["early", "late"])
    }

    static func testRecommendationPicksLargestOverlapOnly() {
        let recording = AudioFileRecordingTime.make(creationDate: base.addingTimeInterval(7_320), duration: 2_640)
        let events = [event("a", "Planning", 7_200, 10_800), event("b", "Review", 9_000, 10_800), event("c", "Lunch", 0, 3_600)]
        precondition(CalendarDayEvents.recommendation(in: events, recording: recording, day: recording!.start)?.id == "a")
        precondition(CalendarDayEvents.recommendation(in: [event("c", "Lunch", 0, 3_600)], recording: recording, day: recording!.start) == nil)
        precondition(CalendarDayEvents.recommendation(in: events, recording: nil, day: base) == nil)
    }

    static func testAppliedTitleUsesRecordingDayOrEventDay() {
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        let meeting = event("a", "주간 기획 회의", 7_200, 10_800)
        let recording = AudioFileRecordingTime.make(creationDate: base.addingTimeInterval(7_320), duration: 600)
        let expectedDay = NoteTitleResolver.calendarAppliedTitle(suggestedTitle: "주간 기획 회의", recordingStartedAt: recording!.start)
        precondition(ImportCalendarTitle.title(for: meeting, recording: recording, chosenDay: base.addingTimeInterval(86_400 * 3)) == expectedDay)
        _ = utc
    }

    static func testInsertionIndexKeepsNewestFirst() {
        let list = [base.addingTimeInterval(300), base.addingTimeInterval(200), base.addingTimeInterval(100)]
        precondition(PipelineHistoryOrdering.insertionIndex(for: base.addingTimeInterval(400), in: list) == 0)
        precondition(PipelineHistoryOrdering.insertionIndex(for: base.addingTimeInterval(150), in: list) == 2)
        precondition(PipelineHistoryOrdering.insertionIndex(for: base, in: list) == 3)
        precondition(PipelineHistoryOrdering.insertionIndex(for: base.addingTimeInterval(200), in: list) == 1)
    }

    static func testImportSelectionSourceRoundTrips() {
        precondition(CalendarMatchSource(rawValue: "import_selection") == .importSelection)
        precondition(CalendarMatchSource(rawValue: "overlap_suggestion") == .overlapSuggestion)
    }

    static func testAppStateImportWiring() throws {
        let source = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)
        precondition(source.contains("func calendarDayEvents(on day: Date) async -> CalendarDayEventsResult"))
        precondition(source.contains("toleratesGoogleFailure: true"), "Apple events survive a Google failure")
        precondition(source.contains("recordingTime: AudioFileRecordingTime?,\n        calendarEvent: CalendarEvent?"))
        precondition(source.contains("timestamp: recordingTime?.end ?? startedAt"))
        precondition(source.contains("recordingStartedAt: recordingTime?.start"))
        precondition(source.contains("source: .importSelection"))
        precondition(source.contains("ImportCalendarTitle.title(for:"))
        precondition(source.contains("PipelineHistoryOrdering.insertionIndex("), "notes insert in time order")
        // Completion keeps placeholder fields (spec §4).
        precondition(source.contains("recordingStartedAt: activeTranscriptionJobs[jobID]?.recordingStartedAt ?? existingEntry?.recordingStartedAt"))
        precondition(source.contains("customTitle: existingEntry?.customTitle"))
        precondition(source.contains("func openCalendarSettings()"))
    }

    static func testBrowserFocusesInsertedNote() throws {
        let browser = try String(contentsOfFile: "Sources/NoteBrowserView.swift", encoding: .utf8)
        precondition(browser.contains("ids.first(where: { !knownHistoryIDs.contains($0) })"), "a new note anywhere in the list is opened")
        precondition(browser.contains("scheduleRecoveryScrollRestore(for: newID)"), "and scrolled into view")
    }

    /// Without a recording time the date is the day the person chose, even
    /// for an event that started the evening before.
    static func testTitleUsesChosenDayWithoutRecordingTime() {
        let overnight = event("n", "Release", -3_600, 3_600)
        let chosen = base.addingTimeInterval(1_800)
        precondition(ImportCalendarTitle.title(for: overnight, recording: nil, chosenDay: chosen)
            == NoteTitleResolver.calendarAppliedTitle(suggestedTitle: "Release", recordingStartedAt: chosen))
    }

    static func testSelectionSurvivesReload() {
        let events = [event("a", "Planning", 0, 600), event("b", "Review", 700, 900)]
        // Not chosen by hand yet: follow the recommendation.
        precondition(ImportCalendarSelection.next(current: events[1].selectionKey, userChose: false, events: events, recommendedKey: events[0].selectionKey, googleFailed: false) == events[0].selectionKey)
        // Chosen by hand and still listed: keep it, including "No event".
        precondition(ImportCalendarSelection.next(current: events[1].selectionKey, userChose: true, events: events, recommendedKey: events[0].selectionKey, googleFailed: false) == events[1].selectionKey)
        precondition(ImportCalendarSelection.next(current: nil, userChose: true, events: events, recommendedKey: events[0].selectionKey, googleFailed: false) == nil)
        // Chosen event gone from the new list: fall back to the recommendation.
        precondition(ImportCalendarSelection.next(current: "google|cal|gone", userChose: true, events: events, recommendedKey: events[0].selectionKey, googleFailed: false) == events[0].selectionKey)
    }

    static func testReviewFixesWiring() throws {
        let app = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)
        precondition(app.contains("@MainActor\n    private func updatePipelineHistoryItem("), "list updates stay on the main actor")
        precondition(app.contains("@MainActor\n    private func insertPipelineHistoryItemInTimeOrder("))
        precondition(app.contains("reportsHealth: false"), "browsing days does not change Google health")
        precondition(app.contains("hasReadableSource:"), "empty sources show the connect hint")
        let browser = try String(contentsOfFile: "Sources/NoteBrowserView.swift", encoding: .utf8)
        precondition(browser.contains("let insertedID = ids.first(where: { !knownHistoryIDs.contains($0) && visibleIDs.contains($0) })"), "nothing open: open the inserted note")
        precondition(browser.contains("if let subtitleDetail {\n                    Text(verbatim: subtitleDetail)"), "recording time on its own line")
        let section = try String(contentsOfFile: "Sources/AudioImportCalendarSection.swift", encoding: .utf8)
        precondition(section.contains("func pickDay("), "user date changes go through one path")
        precondition(!section.contains(".onChange(of: model.day)"), "no second load from onChange")
        precondition(section.contains("guard !dayChosenByUser"), "a late metadata read does not move the user's date")
        precondition(section.contains("ImportCalendarSelection.next("))
        precondition(section.contains("appState.$appleCalendarAuthorization"), "reload when access changes")
        precondition(section.contains("$0.isConnected"), "reload when Google connects")
    }

    /// Google event IDs are unique only per calendar.
    static func testSelectionKeyIncludesCalendar() {
        let shared = CalendarEvent(id: "evt", calendarID: "team", title: "Sync", start: base, end: base.addingTimeInterval(600), isAllDay: false, attendees: [], provider: .google)
        let mine = CalendarEvent(id: "evt", calendarID: "me@example.com", title: "Sync", start: base, end: base.addingTimeInterval(600), isAllDay: false, attendees: [], provider: .google)
        precondition(shared.selectionKey != mine.selectionKey)
    }

    /// An overnight event listed on the next day must not be suggested for
    /// a recording made the day before.
    static func testRecommendationOnlyOnDaysOverlappingRecording() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let midnight = calendar.startOfDay(for: base).addingTimeInterval(86_400)
        let recording = AudioFileRecordingTime.make(creationDate: midnight.addingTimeInterval(-1_800), duration: 1_200)!
        let overnight = CalendarEvent(id: "o", calendarID: "c", title: "Release", start: midnight.addingTimeInterval(-3_600), end: midnight.addingTimeInterval(3_600), isAllDay: false, attendees: [], provider: .google)
        precondition(CalendarDayEvents.recommendation(in: [overnight], recording: recording, day: recording.start, calendar: calendar)?.id == "o")
        precondition(CalendarDayEvents.recommendation(in: [overnight], recording: recording, day: midnight.addingTimeInterval(60), calendar: calendar) == nil)
    }

    /// A transient Google failure must not replace an event picked by hand.
    static func testManualSelectionSurvivesGoogleFailure() {
        let apple = [event("a", "Planning", 0, 600, provider: .apple)]
        let chosenGoogle = "google|cal|g1"
        precondition(ImportCalendarSelection.next(current: chosenGoogle, userChose: true, events: apple, recommendedKey: nil, googleFailed: true) == chosenGoogle)
        precondition(ImportCalendarSelection.next(current: chosenGoogle, userChose: true, events: apple, recommendedKey: nil, googleFailed: false) == nil)
    }

    static func testCodeRabbitFixesWiring() throws {
        let app = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)
        precondition(app.contains("hadPartialFailure"), "partial Google failures reach the sheet")
        precondition(app.contains("googleReadable || !appleIDs.isEmpty"), "an unreadable Google connection shows Calendar Settings")
        let section = try String(contentsOfFile: "Sources/AudioImportCalendarSection.swift", encoding: .utf8)
        precondition(section.contains("ForEach(model.events, id: \\.selectionKey)"))
        precondition(section.contains("ScrollView {") && section.contains(".frame(maxHeight: 220)"), "long lists scroll")
        precondition(section.contains("var isReadyToConfirm: Bool"))
        let browser = try String(contentsOfFile: "Sources/NoteBrowserView.swift", encoding: .utf8)
        precondition(browser.contains("isConfirmEnabled: calendarModel.isReadyToConfirm"), "Transcribe waits for the calendar section")
        precondition(browser.contains(".disabled(!isConfirmEnabled)"))
    }
}
