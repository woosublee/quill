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
        precondition(CalendarDayEvents.recommendation(in: events, recording: recording)?.id == "a")
        precondition(CalendarDayEvents.recommendation(in: [event("c", "Lunch", 0, 3_600)], recording: recording) == nil)
        precondition(CalendarDayEvents.recommendation(in: events, recording: nil) == nil)
    }

    static func testAppliedTitleUsesRecordingDayOrEventDay() {
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        let meeting = event("a", "주간 기획 회의", 7_200, 10_800)
        let recording = AudioFileRecordingTime.make(creationDate: base.addingTimeInterval(7_320), duration: 600)
        let expectedDay = NoteTitleResolver.calendarAppliedTitle(suggestedTitle: "주간 기획 회의", recordingStartedAt: recording!.start)
        precondition(ImportCalendarTitle.title(for: meeting, recording: recording) == expectedDay)
        precondition(ImportCalendarTitle.title(for: meeting, recording: nil) == NoteTitleResolver.calendarAppliedTitle(suggestedTitle: "주간 기획 회의", recordingStartedAt: meeting.start))
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
}
