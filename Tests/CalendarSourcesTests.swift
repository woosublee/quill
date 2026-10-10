import Foundation

@main
struct CalendarSourcesTests {
    static func main() throws {
        testMergeRemovesSameEventFromBothProvidersKeepingFirst()
        testMergeKeepsDifferentEventsAndSortsByStart()
        testMergeTreatsTitleCaseAndWhitespaceAsSame()
        testMergeKeepsSameTitleAtDifferentTimes()
        testParticipantMapping()
        testRowState()
        testVisibleSelectionSkipsMissingCalendarsWithoutDroppingThem()
        testParticipantEmailIsDecoded()
        try testReminderRefreshKeepsExistingRemindersWhenGoogleFails()
        try testAppStateCalendarWiringContract()
        testGroupsBySourceInFirstSeenOrder()
        testSelectionSummaryText()
        try testCombineKeepsAppleWhenGoogleFails()
        testReminderAvailability()
        testSVGPathParsesRelativeAndShorthandCommands()
        testGoogleLogoPathsStayInsideTheirViewBox()
        testCalendarAccessResetTargetsOnlyQuill()
        testGoogleAccountFallsBackToPrimaryCalendarID()
        testSelectAllTogglesEveryListedCalendar()
        try testSelectionSheetHasSelectAll()
        testLastCheckedMovesOnlyOnNewMinute()
        try testReviewFixesWiring()
        testDeclinedRequestCountsAsDeniedWhileStatusLags()
        print("CalendarSourcesTests passed")
    }

    static func event(_ id: String, _ title: String, _ start: TimeInterval, _ end: TimeInterval, provider: CalendarProvider, allDay: Bool = false, attendees: [CalendarEventAttendee] = []) -> CalendarEvent {
        CalendarEvent(id: id, calendarID: provider == .google ? "primary" : "A1B2-UUID", title: title,
                      start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: end),
                      isAllDay: allDay, attendees: attendees, provider: provider)
    }

    /// The same Google account connected directly and through the Mac
    /// Calendar app must yield one reminder, keeping Google's attendees.
    static func testMergeRemovesSameEventFromBothProvidersKeepingFirst() {
        let google = event("g1", "Weekly sync", 1_000, 2_800, provider: .google,
                           attendees: [CalendarEventAttendee(displayName: "Mina", email: "mina@example.com")])
        let apple = event("a1", "Weekly sync", 1_000, 2_800, provider: .apple)
        let merged = CalendarEventMerger.merge([[google], [apple]])
        precondition(merged.count == 1)
        precondition(merged[0].provider == .google)
        precondition(merged[0].attendees.count == 1)
    }

    static func testMergeKeepsDifferentEventsAndSortsByStart() {
        let later = event("g2", "Retro", 5_000, 6_000, provider: .google)
        let earlier = event("a2", "Dentist", 1_000, 2_000, provider: .apple)
        let merged = CalendarEventMerger.merge([[later], [earlier]])
        precondition(merged.map(\.id) == ["a2", "g2"])
    }

    static func testMergeTreatsTitleCaseAndWhitespaceAsSame() {
        let google = event("g3", "Design Review ", 1_000, 2_000, provider: .google)
        let apple = event("a3", "design review", 1_000, 2_000, provider: .apple)
        precondition(CalendarEventMerger.merge([[google], [apple]]).count == 1)
    }

    static func testMergeKeepsSameTitleAtDifferentTimes() {
        let morning = event("g4", "Standup", 1_000, 1_900, provider: .google)
        let tomorrow = event("a4", "Standup", 87_400, 88_300, provider: .apple)
        precondition(CalendarEventMerger.merge([[morning], [tomorrow]]).count == 2)
    }

    static func testParticipantMapping() {
        let me = AppleParticipantData(name: "Woo", url: URL(string: "mailto:me@example.com"), response: .declined, isOptional: false, isCurrentUser: true)
        let a = me.attendee()
        precondition(a.email == "me@example.com" && a.responseStatus == "declined" && a.isSelf && a.displayName == "Woo")
        let room = AppleParticipantData(name: nil, url: URL(string: "https://example.com/room"), response: .pending, isOptional: true, isCurrentUser: false)
        let r = room.attendee()
        precondition(r.email == nil && r.responseStatus == "needsAction" && r.isOptional && r.displayName == nil)
        precondition(AppleParticipantData(name: "X", url: nil, response: .unknown, isOptional: false, isCurrentUser: false).attendee().responseStatus == nil)
    }

    static func testRowState() {
        precondition(AppleCalendarRowState.resolve(isEnabled: false, authorization: .granted, selectedCount: 2) == .notConnected)
        precondition(AppleCalendarRowState.resolve(isEnabled: true, authorization: .denied, selectedCount: 2) == .needsAccess)
        precondition(AppleCalendarRowState.resolve(isEnabled: true, authorization: .notDetermined, selectedCount: 0) == .notConnected)
        precondition(AppleCalendarRowState.resolve(isEnabled: true, authorization: .granted, selectedCount: 0) == .connected(needsSelection: true))
        precondition(AppleCalendarRowState.resolve(isEnabled: true, authorization: .granted, selectedCount: 1) == .connected(needsSelection: false))
    }

    /// A calendar missing for a moment (sync, account off) is skipped but
    /// stays selected, so it comes back on its own.
    static func testVisibleSelectionSkipsMissingCalendarsWithoutDroppingThem() {
        let available = [AppleCalendarInfo(id: "A", title: "Personal", sourceTitle: "iCloud", colorHex: nil)]
        let selected: Set<String> = ["A", "TEMPORARILY-MISSING"]
        precondition(AppleCalendarSelection.visible(selected, available: available).map(\.id) == ["A"])
        precondition(selected.count == 2)
    }

    static func testParticipantEmailIsDecoded() {
        let plus = AppleParticipantData(name: nil, url: URL(string: "mailto:first%2Blast@example.com"), response: .accepted, isOptional: false, isCurrentUser: false)
        precondition(plus.attendee().email == "first+last@example.com")
        let query = AppleParticipantData(name: nil, url: URL(string: "mailto:a@example.com?subject=hi"), response: .accepted, isOptional: false, isCurrentUser: false)
        precondition(query.attendee().email == "a@example.com")
    }

    /// Reminder scheduling must keep the last good reminders when Google
    /// fails, instead of rescheduling from Apple events alone.
    static func testReminderRefreshKeepsExistingRemindersWhenGoogleFails() throws {
        let apple = [event("a6", "Sync", 1_000, 2_000, provider: .apple)]
        do {
            _ = try CalendarEventCollection.combine(google: .failure(FetchFailure()), apple: apple, toleratesGoogleFailure: false)
            preconditionFailure("reminder refresh must fail when Google fails")
        } catch is FetchFailure {}
        let titles = try CalendarEventCollection.combine(google: .failure(FetchFailure()), apple: apple, toleratesGoogleFailure: true)
        precondition(titles.map(\.id) == ["a6"])
    }

    /// Wiring that only shows up in AppState and Settings source.
    static func testAppStateCalendarWiringContract() throws {
        let appState = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)
        let clear = block(appState, from: "private func clearGoogleCalendarConnectionState()", to: "\n    }\n")
        precondition(clear.contains("scheduleCalendarRecordingReminderRefresh()"), "Google disconnect keeps Apple reminders running")
        precondition(!clear.contains("stopCalendarRecordingReminderSchedulerIfNeeded()"), "Google disconnect must not stop all reminders")
        precondition(clear.contains("googleReminderEventsCache = nil"), "Google disconnect forgets saved Google events")
        let reload = block(appState, from: "func reloadAppleCalendars()", to: "\n    }\n")
        precondition(!reload.contains("pruned"), "reload must not drop selected calendars")
        precondition(reload.contains("scheduleCalendarRecordingReminderRefresh(reusingGoogleEvents: true)"), "reload reschedules reminders without asking Google again")
        precondition(appState.contains("appleCalendarService.resetStore()"), "store is recreated after access changes")
        precondition(appState.contains("appleCalendarChangeDebounce"), "store-changed bursts are debounced")
        precondition(appState.contains("toleratesGoogleFailure: false"), "reminders keep existing reminders on Google failure")
        let settings = try String(contentsOfFile: "Sources/SettingsView.swift", encoding: .utf8)
        let row = block(settings, from: "private var appleCalendarRow: some View", to: "\n    }\n\n")
        let needsAccess = block(row, from: "case .needsAccess:\n                    Button(", to: "case .connected(")
        precondition(needsAccess.contains("appState.disconnectAppleCalendar()"), "denied state can be turned off")
        precondition(needsAccess.contains("Button(\"Ask Again\")"), "denied state can ask for access again")
        precondition(needsAccess.contains("appState.askForAppleCalendarAccessAgain()"))
        precondition(needsAccess.contains("appState.guidePermission(.calendars)"), "System Settings stays reachable")
        let askAgain = block(appState, from: "func askForAppleCalendarAccessAgain()", to: "\n    }\n")
        precondition(askAgain.contains("AppleCalendarAccessReset.run("), "resets only Quill's Calendar decision")
        precondition(askAgain.contains("requestAccess()"), "then shows the system prompt again")
        precondition(appState.contains("appleCalendarLastRequestDeclined = !granted"), "a declined request is remembered")
        precondition(appState.contains("AppleCalendarAuthorization.effective(\n            reported:"), "row state uses the request result")
    }

    static func block(_ source: String, from start: String, to end: String) -> String {
        guard let startRange = source.range(of: start),
              let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex) else {
            preconditionFailure("Expected source block from \(start)")
        }
        return String(source[startRange.lowerBound..<endRange.upperBound])
    }

    static func testGroupsBySourceInFirstSeenOrder() {
        let calendars = [
            AppleCalendarInfo(id: "1", title: "Work", sourceTitle: "Exchange", colorHex: nil),
            AppleCalendarInfo(id: "2", title: "Personal", sourceTitle: "iCloud", colorHex: nil),
            AppleCalendarInfo(id: "3", title: "Family", sourceTitle: "iCloud", colorHex: nil),
        ]
        let groups = calendars.groupedBySource()
        precondition(groups.map(\.title) == ["Exchange", "iCloud"])
        precondition(groups[1].calendars.map(\.title) == ["Family", "Personal"])
    }

    static func testSelectionSummaryText() {
        let bundle = Bundle.main
        precondition(CalendarSelectionSummary.names([], language: "en", bundle: bundle) == nil)
        precondition(CalendarSelectionSummary.names(["Personal"], language: "en", bundle: bundle) == "(Personal)")
        precondition(CalendarSelectionSummary.names(["Personal", "Work"], language: "en", bundle: bundle) == "(Personal, Work)")
        precondition(CalendarSelectionSummary.names(["Personal", "Work", "Family", "Gym"], language: "en", bundle: bundle) == "(Personal, Work and 2 more)")

        precondition(CalendarSelectionSummary.status(account: "a@example.com", hasSelection: true, checkedTime: "2:30 PM", language: "en", bundle: bundle) == "Last checked 2:30 PM · a@example.com")
        precondition(CalendarSelectionSummary.status(account: "a@example.com", hasSelection: false, checkedTime: nil, language: "en", bundle: bundle) == "Choose calendars to use · a@example.com")
        precondition(CalendarSelectionSummary.status(account: nil, hasSelection: true, checkedTime: "2:30 PM", language: "en", bundle: bundle) == "Last checked 2:30 PM")
        precondition(CalendarSelectionSummary.status(account: nil, hasSelection: false, checkedTime: nil, language: "en", bundle: bundle) == "Choose calendars to use")
        precondition(CalendarSelectionSummary.status(account: nil, hasSelection: true, checkedTime: nil, language: "en", bundle: bundle) == nil)
        // A check from another day shows its date too.
        let now = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        let earlierToday = now.addingTimeInterval(-60)
        let yesterday = now.addingTimeInterval(-86_400)
        precondition(CalendarSelectionSummary.checkedTimeText(earlierToday, now: now) == earlierToday.formatted(date: .omitted, time: .shortened))
        precondition(CalendarSelectionSummary.checkedTimeText(yesterday, now: now) == yesterday.formatted(date: .abbreviated, time: .shortened))
    }

    struct FetchFailure: Error {}

    /// A Google token that needs reconnecting must not stop Apple events
    /// from driving reminders and note titles.
    static func testCombineKeepsAppleWhenGoogleFails() throws {
        let apple = [event("a5", "Sync", 1_000, 2_000, provider: .apple)]
        let combined = try CalendarEventCollection.combine(google: .failure(FetchFailure()), apple: apple, toleratesGoogleFailure: true)
        precondition(combined.map(\.id) == ["a5"])
        do {
            _ = try CalendarEventCollection.combine(google: .failure(FetchFailure()), apple: nil, toleratesGoogleFailure: true)
            preconditionFailure("Google-only failure must still throw")
        } catch is FetchFailure {}
        let none = try CalendarEventCollection.combine(google: nil, apple: nil, toleratesGoogleFailure: true)
        precondition(none.isEmpty)
        let google = [event("g5", "Sync", 1_000, 2_000, provider: .google)]
        let both = try CalendarEventCollection.combine(google: .success(google), apple: apple, toleratesGoogleFailure: false)
        precondition(both.map(\.id) == ["g5"])
    }

    static func testReminderAvailability() {
        precondition(!CalendarReminderAvailability.isAvailable(googleConnected: false, googleSelected: 0, appleRowState: .notConnected, appleSelected: 0))
        precondition(CalendarReminderAvailability.isAvailable(googleConnected: true, googleSelected: 1, appleRowState: .notConnected, appleSelected: 0))
        precondition(CalendarReminderAvailability.isAvailable(googleConnected: false, googleSelected: 0, appleRowState: .connected(needsSelection: false), appleSelected: 2))
        precondition(!CalendarReminderAvailability.isAvailable(googleConnected: false, googleSelected: 0, appleRowState: .needsAccess, appleSelected: 2))
        precondition(!CalendarReminderAvailability.isAvailable(googleConnected: true, googleSelected: 0, appleRowState: .connected(needsSelection: true), appleSelected: 0))
    }

    static func testSVGPathParsesRelativeAndShorthandCommands() {
        let square = SVGPath.cgPath("M0 0h10v10H0z")
        precondition(square.boundingBoxOfPath == CGRect(x: 0, y: 0, width: 10, height: 10))
        // Packed numbers: "-.5-1" is two numbers, ".27.5" is two numbers.
        let packed = SVGPath.cgPath("M1 1l-.5-1l.25.5")
        precondition(abs(packed.currentPoint.x - 0.75) < 0.0001 && abs(packed.currentPoint.y - 0.5) < 0.0001)
        let curve = SVGPath.cgPath("M0 0c0 10 10 10 10 0s10-10 10 0")
        precondition(abs(curve.currentPoint.x - 20) < 0.0001 && abs(curve.currentPoint.y) < 0.0001)
    }

    static func testGoogleLogoPathsStayInsideTheirViewBox() {
        precondition(GoogleLogoMark.paths.count == 4)
        for (data, _) in GoogleLogoMark.paths {
            let box = SVGPath.cgPath(data).boundingBoxOfPath
            precondition(box.minX >= -0.01 && box.minY >= -0.01 && box.maxX <= 48.01 && box.maxY <= 48.01, "Google G path out of bounds")
            precondition(box.width > 5 && box.height > 5)
        }
    }

    /// A denied app is not listed under Privacy & Security › Calendars, so
    /// Quill resets only its own Calendar decision before asking again.
    static func testCalendarAccessResetTargetsOnlyQuill() {
        precondition(AppleCalendarAccessReset.arguments(bundleID: "com.example.quill") == ["reset", "Calendar", "com.example.quill"])
        precondition(AppleCalendarAccessReset.arguments(bundleID: nil) == nil)
        precondition(AppleCalendarAccessReset.arguments(bundleID: "") == nil)
        precondition(AppleCalendarAccessReset.executablePath == "/usr/bin/tccutil")
    }

    /// After a reset, macOS can keep reporting "not determined" in the same
    /// process even though the person just chose Don't Allow.
    static func testDeclinedRequestCountsAsDeniedWhileStatusLags() {
        precondition(AppleCalendarAuthorization.effective(reported: .notDetermined, lastRequestDeclined: true) == .denied)
        precondition(AppleCalendarAuthorization.effective(reported: .notDetermined, lastRequestDeclined: false) == .notDetermined)
        precondition(AppleCalendarAuthorization.effective(reported: .granted, lastRequestDeclined: true) == .granted)
        precondition(AppleCalendarAuthorization.effective(reported: .denied, lastRequestDeclined: false) == .denied)
    }

    /// Some stored Google connections have no email; the primary calendar's
    /// ID is the account address.
    static func testGoogleAccountFallsBackToPrimaryCalendarID() {
        let calendars = [
            GoogleCalendarInfo(id: "team@group.calendar.google.com", summary: "Team", summaryOverride: nil, primary: false, accessRole: "reader"),
            GoogleCalendarInfo(id: "person@example.com", summary: "person@example.com", summaryOverride: nil, primary: true, accessRole: "owner"),
        ]
        precondition(GoogleCalendarAccount.label(accountEmail: nil, calendars: calendars) == "person@example.com")
        precondition(GoogleCalendarAccount.label(accountEmail: "  ", calendars: calendars) == "person@example.com")
        precondition(GoogleCalendarAccount.label(accountEmail: "stored@example.com", calendars: calendars) == "stored@example.com")
        precondition(GoogleCalendarAccount.label(accountEmail: nil, calendars: []) == nil)
    }

    static func testSelectAllTogglesEveryListedCalendar() {
        let listed = ["A", "B", "C"]
        precondition(!CalendarBulkSelection.allSelected(["A", "B"], listed: listed))
        precondition(CalendarBulkSelection.allSelected(["A", "B", "C", "GONE"], listed: listed))
        precondition(!CalendarBulkSelection.allSelected([], listed: []))
        // Select All keeps choices for calendars that are hidden right now.
        precondition(CalendarBulkSelection.toggled(["A", "GONE"], listed: listed) == ["A", "B", "C", "GONE"])
        precondition(CalendarBulkSelection.toggled(["A", "B", "C", "GONE"], listed: listed) == ["GONE"])
    }

    static func testSelectionSheetHasSelectAll() throws {
        let settings = try String(contentsOfFile: "Sources/SettingsView.swift", encoding: .utf8)
        let sheet = block(settings, from: "private struct CalendarSelectionSheet: View", to: "    @ViewBuilder\n    private var googleList")
        precondition(sheet.contains("CalendarBulkSelection.allSelected("), "sheet knows whether all are selected")
        precondition(sheet.contains("\"Deselect All\"") && sheet.contains("\"Select All\""), "sheet offers Select All / Deselect All")
        let appState = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)
        precondition(appState.contains("func setGoogleCalendarSelection(_ calendarIDs: Set<String>)"))
        precondition(appState.contains("func setAppleCalendarSelection(_ calendarIDs: Set<String>)"))
    }

    static func testLastCheckedMovesOnlyOnNewMinute() {
        let base = Date(timeIntervalSince1970: 1_000_020)
        precondition(CalendarCheckTime.shouldUpdate(previous: nil, now: base))
        precondition(!CalendarCheckTime.shouldUpdate(previous: base, now: base.addingTimeInterval(10)))
        precondition(CalendarCheckTime.shouldUpdate(previous: base, now: base.addingTimeInterval(60)))
    }

    static func testReviewFixesWiring() throws {
        let settings = try String(contentsOfFile: "Sources/SettingsView.swift", encoding: .utf8)
        let row = block(settings, from: "private var appleCalendarRow: some View", to: "\n    }\n\n")
        precondition(!row.contains("appState.reloadAppleCalendars()"), "Apple refresh re-checks access first")
        precondition(row.contains("names: appleConnected ? appleSelectedNames : []"), "names only while connected")
        precondition(row.contains(".disabled(appState.isAskingForAppleCalendarAccess)"), "Ask Again is locked while running")
        precondition(settings.contains("case .unknown:\n                Label(\"Connected\", systemImage: \"checkmark.circle\")\n                    .foregroundStyle(.secondary)"), "unchecked Google is not green")

        let appState = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)
        let askAgain = block(appState, from: "func askForAppleCalendarAccessAgain()", to: "\n    }\n")
        precondition(askAgain.contains("guard !isAskingForAppleCalendarAccess"), "one Ask Again at a time")
        precondition(askAgain.contains("guidePermission(.calendars)"), "failed reset falls back to System Settings")
        precondition(!appState.contains("appleCalendarLastCheckedAt = Date()"), "check time moves only after a real read")
        let single = block(appState, from: "func setAppleCalendarSelected(_ calendarID: String, isSelected: Bool)", to: "\n    }\n")
        precondition(single.contains("setAppleCalendarSelection("), "single toggle reuses the set-based setter")
        let googleSingle = block(appState, from: "func setGoogleCalendarSelected(_ calendarID: String, isSelected: Bool)", to: "\n    }\n")
        precondition(googleSingle.contains("setGoogleCalendarSelection("))
    }
}
