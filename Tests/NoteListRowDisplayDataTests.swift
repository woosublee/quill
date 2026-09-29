import Foundation

@main
struct NoteListRowDisplayDataTests {
    static func main() {
        testFormatsRowDate()
        testFormatsExplicitLocaleRowDates()
        testFormatsExplicitLocaleDetailTimestamps()
        testFormatsEnglishWeekdayAndMonthStyles()
        testKeepsCurrentCalendarWithLocaleSpecificTemplates()
        testFormatsJapaneseDetailTimestamp()
        testRepeatedFormattingRemainsStable()
        testCalendarAndTimeZoneFormattingRemainIsolated()
        testHourCycleFormattingRemainsIsolated()
        testConcurrentFormattingRemainsStable()
        testFormatsSameMorningRowDateStartTime()
        testFormatsMorningToAfternoonRowDateStartTime()
        testFormatsCrossDateRowDateStartTime()
        testFormatsSameMorningRecordingInterval()
        testFormatsMorningToAfternoonRecordingInterval()
        testFormatsSameAfternoonRecordingInterval()
        testFormatsCrossDateRecordingInterval()
        testUsesSingleTimestampWhenRecordingIntervalIsMissing()
        testUsesItemCustomTitleAndContentPreview()
        testDropsAutomaticTitleFromPreview()
        testWhitespaceOnlyCustomTitleDoesNotForceContentPreview()
        testLegacyFailurePreviewUsesSafeMessage()
        testLegacyFailurePreviewHandlesMissingSpaceAfterPrefix()
        testRecoveredRecordingUsesFriendlyStatusAndPreview()
        testDegradedRecoveredRecordingNamesAvailableSource()
        testStorageInterruptionPreviewCombinesCauseAndMode()
        testTranscribingTitleAndEmptyPreview()
        testPostProcessingNoteShowsPostProcessingTitle()
        testRowAccessibilityLabelSpellsOutState()
        testRetriedNoteKeepsItsNameInsteadOfTheStage()
        testCloudChunkProgressDisplaysActiveChunk()
        testRestoredCloudProgressDisplaysWaitingCopy()
        testCloudProgressCopyLocalizesInKorean()
        testRetryingItemHidesExistingPreview()
        testAudioOnlyRowUsesBlueStateAndNotTranscribedPreview()
        testHasMeetingSummaryReflectsStoredSummaryPresence()
        testOnlyFinishedNotesAreBulkSelectable()
        testRecordingPlaceholderRowCarriesRecordingStart()
        testRecordingElapsedFormatter()
        testUnfinishedRecordingNoteNeedsNoContentOrAudio()
        print("NoteListRowDisplayDataTests passed")
    }

    private static func testRecordingPlaceholderRowCarriesRecordingStart() {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let recording = historyItem(
            recordingStartedAt: startedAt,
            transcript: "",
            postProcessingStatus: "live-recording"
        )
        let data = NoteListRowDisplayData(item: recording, retryingIDs: [])
        assert(data.status == .recording)
        assert(data.recordingStartedAt == startedAt, "Recording row shows a running elapsed time")
        assert(data.displayTitle == "New Recording")
        assert(data.preview.isEmpty)

        let titled = historyItem(
            recordingStartedAt: startedAt,
            transcript: "",
            postProcessingStatus: "live-recording",
            customTitle: "Weekly sync"
        )
        let titledData = NoteListRowDisplayData(item: titled, retryingIDs: [])
        assert(titledData.displayTitle == "Weekly sync")
        assert(titledData.recordingStartedAt == startedAt, "The elapsed time stays in the status corner")

        let titledLikePlaceholder = historyItem(
            recordingStartedAt: startedAt,
            transcript: "",
            postProcessingStatus: "live-recording",
            customTitle: "Recording..."
        )
        let titledLikePlaceholderData = NoteListRowDisplayData(item: titledLikePlaceholder, retryingIDs: [])
        assert(
            titledLikePlaceholderData.displayTitle == "Recording...",
            "A typed title that matches the placeholder text is still the user's title"
        )

        let liveText = historyItem(
            recordingStartedAt: startedAt,
            transcript: "Let's review the roadmap.",
            postProcessingStatus: "live-recording"
        )
        let liveTextData = NoteListRowDisplayData(item: liveText, retryingIDs: [])
        assert(liveTextData.recordingStartedAt == startedAt)
        assert(liveTextData.displayTitle != "New Recording", "Live text names the note")

        let finished = historyItem(recordingStartedAt: startedAt, transcript: "Done.")
        assert(NoteListRowDisplayData(item: finished, retryingIDs: []).recordingStartedAt == nil)
    }

    private static func testRecordingElapsedFormatter() {
        let start = Date(timeIntervalSince1970: 10_000)
        assert(RecordingElapsedFormatter.string(from: start, to: start) == "00:00")
        assert(RecordingElapsedFormatter.string(from: start, to: start.addingTimeInterval(192.9)) == "03:12")
        assert(RecordingElapsedFormatter.string(from: start, to: start.addingTimeInterval(3_725)) == "1:02:05")
        assert(RecordingElapsedFormatter.string(from: start, to: start.addingTimeInterval(-5)) == "00:00")
    }

    private static func testUnfinishedRecordingNoteNeedsNoContentOrAudio() {
        let empty = historyItem(transcript: "", postProcessingStatus: "live-recording")
        assert(empty.isUnfinishedRecordingNote)

        let withText = historyItem(transcript: "Partial words", postProcessingStatus: "live-recording")
        assert(!withText.isUnfinishedRecordingNote, "Live text is kept")

        let placeholder = historyItem(
            transcript: "",
            postProcessingStatus: PipelineHistoryItem.transcriptionRecoveryPlaceholderStatus
        )
        assert(!placeholder.isUnfinishedRecordingNote, "A saved recording waiting for transcription is kept")
    }

    private static func testHasMeetingSummaryReflectsStoredSummaryPresence() {
        let withSummary = historyItem(
            transcript: "Decision: ship Friday.",
            meetingSummaryJSON: Data("{}".utf8)
        )
        let withoutSummary = historyItem(transcript: "Decision: ship Friday.")

        let withSummaryData = NoteListRowDisplayData(item: withSummary, retryingIDs: [])
        let withoutSummaryData = NoteListRowDisplayData(item: withoutSummary, retryingIDs: [])

        assert(withSummaryData.hasMeetingSummary, "Row with a stored summary reports hasMeetingSummary")
        assert(!withoutSummaryData.hasMeetingSummary, "Row without a stored summary reports no summary")
    }

    private static func testFormatsRowDate() {
        let item = historyItem(
            timestamp: date(year: 2025, month: 5, day: 5, hour: 9, minute: 0),
            transcript: "Team sync notes"
        )

        let rowDate = NoteTimestampFormatter.rowTimestamp(for: item, locale: Locale(identifier: "ko_KR"))

        assert(rowDate == "5월 5일 (월) 오전 9:00", "Unexpected row date: \(rowDate)")
    }

    private static func testFormatsExplicitLocaleRowDates() {
        let item = historyItem(
            timestamp: date(year: 2026, month: 5, day: 15, hour: 11, minute: 12),
            recordingStartedAt: date(year: 2026, month: 5, day: 15, hour: 10, minute: 38),
            recordingEndedAt: date(year: 2026, month: 5, day: 15, hour: 11, minute: 12),
            transcript: "Morning notes"
        )

        let english = NoteTimestampFormatter.rowTimestamp(for: item, locale: Locale(identifier: "en_US"))
        let korean = NoteTimestampFormatter.rowTimestamp(for: item, locale: Locale(identifier: "ko_KR"))
        let japanese = NoteTimestampFormatter.rowTimestamp(for: item, locale: Locale(identifier: "ja_JP"))

        assert(english == "Fri, May 15 at 10:38 AM", "Unexpected English row date: \(english)")
        assert(korean == "5월 15일 (금) 오전 10:38", "Unexpected Korean row date: \(korean)")
        assert(japanese == "5月15日(金) 10:38", "Unexpected Japanese row date: \(japanese)")
    }

    private static func testFormatsExplicitLocaleDetailTimestamps() {
        let item = historyItem(
            timestamp: date(year: 2026, month: 5, day: 15, hour: 11, minute: 12),
            recordingStartedAt: date(year: 2026, month: 5, day: 15, hour: 10, minute: 38),
            recordingEndedAt: date(year: 2026, month: 5, day: 15, hour: 11, minute: 12),
            transcript: "Morning notes"
        )

        let english = NoteTimestampFormatter.detailTimestamp(for: item, locale: Locale(identifier: "en_US"))
        let korean = NoteTimestampFormatter.detailTimestamp(for: item, locale: Locale(identifier: "ko_KR"))

        assert(english == "Fri, May 15, 2026, 10:38 – 11:12 AM", "Unexpected English interval: \(english)")
        assert(korean == "2026년 5월 15일 (금) 오전 10:38~11:12", "Unexpected Korean interval: \(korean)")
    }

    private static func testFormatsEnglishWeekdayAndMonthStyles() {
        let item = historyItem(
            timestamp: date(year: 2026, month: 8, day: 10, hour: 11, minute: 12),
            recordingStartedAt: date(year: 2026, month: 8, day: 10, hour: 10, minute: 0),
            recordingEndedAt: date(year: 2026, month: 8, day: 10, hour: 11, minute: 12),
            transcript: "English notes"
        )
        let locale = Locale(identifier: "en_US")

        assert(
            NoteTimestampFormatter.rowTimestamp(for: item, locale: locale)
                == "Mon, August 10 at 10:00 AM"
        )
        assert(
            NoteTimestampFormatter.detailTimestamp(for: item, locale: locale)
                == "Mon, Aug 10, 2026, 10:00 – 11:12 AM"
        )
    }

    private static func testKeepsCurrentCalendarWithLocaleSpecificTemplates() {
        let item = historyItem(
            timestamp: date(year: 2026, month: 8, day: 10, hour: 11, minute: 12),
            recordingStartedAt: date(year: 2026, month: 8, day: 10, hour: 10, minute: 0),
            recordingEndedAt: date(year: 2026, month: 8, day: 10, hour: 11, minute: 12),
            transcript: "Calendar notes"
        )
        let locale = Locale(identifier: "ar_SA")

        // The prior FormatStyle path retained Calendar.current despite this
        // locale's default Islamic calendar. Adding a weekday must not rebase
        // the stored recording date into a different calendar.
        let legacyItem = historyItem(
            timestamp: date(year: 2026, month: 8, day: 10, hour: 10, minute: 0),
            transcript: "Legacy calendar notes"
        )

        assert(NoteTimestampFormatter.rowTimestamp(for: item, locale: locale).contains("أغسطس"))
        assert(NoteTimestampFormatter.detailTimestamp(for: item, locale: locale).contains("أغسطس"))
        assert(NoteTimestampFormatter.detailTimestamp(for: legacyItem, locale: locale).contains("أغسطس"))
    }

    private static func testFormatsJapaneseDetailTimestamp() {
        let item = historyItem(
            timestamp: date(year: 2026, month: 5, day: 15, hour: 11, minute: 12),
            recordingStartedAt: date(year: 2026, month: 5, day: 15, hour: 10, minute: 38),
            recordingEndedAt: date(year: 2026, month: 5, day: 15, hour: 11, minute: 12),
            transcript: "Morning notes"
        )

        let japanese = NoteTimestampFormatter.detailTimestamp(for: item, locale: Locale(identifier: "ja_JP"))

        assert(japanese == "2026年5月15日(金) 10時38分～11時12分", "Unexpected Japanese interval: \(japanese)")
    }

    private static func testRepeatedFormattingRemainsStable() {
        let item = historyItem(
            timestamp: date(year: 2026, month: 5, day: 15, hour: 11, minute: 12),
            recordingStartedAt: date(year: 2026, month: 5, day: 15, hour: 10, minute: 38),
            recordingEndedAt: date(year: 2026, month: 5, day: 15, hour: 11, minute: 12),
            transcript: "Repeated formatting"
        )
        let locale = Locale(identifier: "ko_KR")
        let expected = NoteTimestampFormatter.detailTimestamp(for: item, locale: locale)

        for _ in 0..<100 {
            assert(
                NoteTimestampFormatter.detailTimestamp(for: item, locale: locale)
                    == expected
            )
        }
    }

    private static func testCalendarAndTimeZoneFormattingRemainIsolated() {
        let timestamp = date(
            year: 2026,
            month: 1,
            day: 1,
            hour: 2,
            minute: 30,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        let item = historyItem(timestamp: timestamp, transcript: "Time zones")
        let locale = Locale(identifier: "en_US")
        let utc = TimeZone(secondsFromGMT: 0)!
        let honolulu = TimeZone(identifier: "Pacific/Honolulu")!
        let gregorian = Calendar(identifier: .gregorian)
        let buddhist = Calendar(identifier: .buddhist)

        let utcValue = NoteTimestampFormatter.rowTimestamp(
            for: item,
            locale: locale,
            calendar: gregorian,
            timeZone: utc
        )
        let honoluluValue = NoteTimestampFormatter.rowTimestamp(
            for: item,
            locale: locale,
            calendar: gregorian,
            timeZone: honolulu
        )
        let gregorianValue = NoteTimestampFormatter.detailTimestamp(
            for: item,
            locale: locale,
            calendar: gregorian,
            timeZone: utc
        )
        let buddhistValue = NoteTimestampFormatter.detailTimestamp(
            for: item,
            locale: locale,
            calendar: buddhist,
            timeZone: utc
        )
        let gregorianAgain = NoteTimestampFormatter.detailTimestamp(
            for: item,
            locale: locale,
            calendar: gregorian,
            timeZone: utc
        )

        assert(utcValue != honoluluValue, "time-zone-specific values differ")
        assert(gregorianValue != buddhistValue, "calendar-specific values differ")
        assert(buddhistValue.contains("2569"), "Buddhist calendar uses year 2569")
        assert(gregorianAgain == gregorianValue, "alternating calendars do not contaminate Gregorian output")
    }

    private static func testHourCycleFormattingRemainsIsolated() {
        let item = historyItem(
            timestamp: date(
                year: 2026,
                month: 5,
                day: 15,
                hour: 13,
                minute: 12,
                timeZone: TimeZone(secondsFromGMT: 0)!
            ),
            transcript: "Hour cycles"
        )
        let utc = TimeZone(secondsFromGMT: 0)!
        var twelveHourComponents = Locale.Components(
            languageCode: .english,
            languageRegion: .unitedStates
        )
        twelveHourComponents.hourCycle = .oneToTwelve
        var twentyFourHourComponents = twelveHourComponents
        twentyFourHourComponents.hourCycle = .zeroToTwentyThree
        let twelveHourLocale = Locale(components: twelveHourComponents)
        let twentyFourHourLocale = Locale(components: twentyFourHourComponents)

        assert(twelveHourLocale.hourCycle != twentyFourHourLocale.hourCycle)

        let twelveHourValue = NoteTimestampFormatter.rowTimestamp(
            for: item,
            locale: twelveHourLocale,
            timeZone: utc
        )
        let twentyFourHourValue = NoteTimestampFormatter.rowTimestamp(
            for: item,
            locale: twentyFourHourLocale,
            timeZone: utc
        )
        let twelveHourAgain = NoteTimestampFormatter.rowTimestamp(
            for: item,
            locale: twelveHourLocale,
            timeZone: utc
        )

        assert(twelveHourValue.contains("PM"), "12-hour value preserves AM/PM")
        assert(twentyFourHourValue.contains("13:12"), "24-hour value preserves hour cycle")
        assert(twelveHourAgain == twelveHourValue, "alternating hour cycles do not contaminate 12-hour output")
    }

    private static func testConcurrentFormattingRemainsStable() {
        let item = historyItem(
            timestamp: date(year: 2026, month: 5, day: 15, hour: 11, minute: 12),
            recordingStartedAt: date(year: 2026, month: 5, day: 15, hour: 10, minute: 38),
            recordingEndedAt: date(year: 2026, month: 5, day: 15, hour: 11, minute: 12),
            transcript: "Concurrent formatting"
        )
        let locale = Locale(identifier: "en_US")
        let expected = NoteTimestampFormatter.detailTimestamp(for: item, locale: locale)
        let results = LockedStrings()

        DispatchQueue.concurrentPerform(iterations: 200) { _ in
            results.append(
                NoteTimestampFormatter.detailTimestamp(for: item, locale: locale)
            )
        }

        assert(results.values.count == 200)
        assert(results.values.allSatisfy { $0 == expected })
    }

    private static func testFormatsSameMorningRowDateStartTime() {
        let item = historyItem(
            timestamp: date(year: 2026, month: 5, day: 15, hour: 11, minute: 12),
            recordingStartedAt: date(year: 2026, month: 5, day: 15, hour: 10, minute: 38),
            recordingEndedAt: date(year: 2026, month: 5, day: 15, hour: 11, minute: 12),
            transcript: "Morning notes"
        )

        let data = NoteListRowDisplayData(
            item: item,
            retryingIDs: [],
            locale: Locale(identifier: "ko_KR")
        )

        assert(data.rowDate == "5월 15일 (금) 오전 10:38", "Unexpected row date: \(data.rowDate)")
    }

    private static func testFormatsMorningToAfternoonRowDateStartTime() {
        let item = historyItem(
            timestamp: date(year: 2026, month: 5, day: 15, hour: 12, minute: 12),
            recordingStartedAt: date(year: 2026, month: 5, day: 15, hour: 10, minute: 38),
            recordingEndedAt: date(year: 2026, month: 5, day: 15, hour: 12, minute: 12),
            transcript: "Noon notes"
        )

        let data = NoteListRowDisplayData(
            item: item,
            retryingIDs: [],
            locale: Locale(identifier: "ko_KR")
        )

        assert(data.rowDate == "5월 15일 (금) 오전 10:38", "Unexpected row date: \(data.rowDate)")
    }

    private static func testFormatsCrossDateRowDateStartTime() {
        let item = historyItem(
            timestamp: date(year: 2026, month: 5, day: 16, hour: 0, minute: 10),
            recordingStartedAt: date(year: 2026, month: 5, day: 15, hour: 23, minute: 40),
            recordingEndedAt: date(year: 2026, month: 5, day: 16, hour: 0, minute: 10),
            transcript: "Late notes"
        )

        let data = NoteListRowDisplayData(
            item: item,
            retryingIDs: [],
            locale: Locale(identifier: "ko_KR")
        )

        assert(data.rowDate == "5월 15일 (금) 오후 11:40", "Unexpected row date: \(data.rowDate)")
    }

    private static func testFormatsSameMorningRecordingInterval() {
        let item = historyItem(
            timestamp: date(year: 2026, month: 5, day: 15, hour: 11, minute: 12),
            recordingStartedAt: date(year: 2026, month: 5, day: 15, hour: 10, minute: 38),
            recordingEndedAt: date(year: 2026, month: 5, day: 15, hour: 11, minute: 12),
            transcript: "Morning notes"
        )

        let formatted = NoteTimestampFormatter.detailTimestamp(for: item, locale: Locale(identifier: "ko_KR"))

        assert(formatted == "2026년 5월 15일 (금) 오전 10:38~11:12", "Unexpected interval: \(formatted)")
    }

    private static func testFormatsMorningToAfternoonRecordingInterval() {
        let item = historyItem(
            timestamp: date(year: 2026, month: 5, day: 15, hour: 12, minute: 12),
            recordingStartedAt: date(year: 2026, month: 5, day: 15, hour: 10, minute: 38),
            recordingEndedAt: date(year: 2026, month: 5, day: 15, hour: 12, minute: 12),
            transcript: "Noon notes"
        )

        let formatted = NoteTimestampFormatter.detailTimestamp(for: item, locale: Locale(identifier: "ko_KR"))

        assert(formatted == "2026년 5월 15일 (금) 오전 10:38 ~ 오후 12:12", "Unexpected interval: \(formatted)")
    }

    private static func testFormatsSameAfternoonRecordingInterval() {
        let item = historyItem(
            timestamp: date(year: 2026, month: 5, day: 15, hour: 14, minute: 22),
            recordingStartedAt: date(year: 2026, month: 5, day: 15, hour: 13, minute: 5),
            recordingEndedAt: date(year: 2026, month: 5, day: 15, hour: 14, minute: 22),
            transcript: "Afternoon notes"
        )

        let formatted = NoteTimestampFormatter.detailTimestamp(for: item, locale: Locale(identifier: "ko_KR"))

        assert(formatted == "2026년 5월 15일 (금) 오후 1:05~2:22", "Unexpected interval: \(formatted)")
    }

    private static func testFormatsCrossDateRecordingInterval() {
        let item = historyItem(
            timestamp: date(year: 2026, month: 5, day: 16, hour: 0, minute: 10),
            recordingStartedAt: date(year: 2026, month: 5, day: 15, hour: 23, minute: 40),
            recordingEndedAt: date(year: 2026, month: 5, day: 16, hour: 0, minute: 10),
            transcript: "Late notes"
        )

        let formatted = NoteTimestampFormatter.detailTimestamp(for: item, locale: Locale(identifier: "ko_KR"))

        assert(formatted == "2026년 5월 15일 (금) 오후 11:40 ~ 2026년 5월 16일 (토) 오전 12:10", "Unexpected interval: \(formatted)")
    }

    private static func testUsesSingleTimestampWhenRecordingIntervalIsMissing() {
        let item = historyItem(
            timestamp: date(year: 2026, month: 5, day: 15, hour: 10, minute: 38),
            transcript: "Imported notes"
        )

        let formatted = NoteTimestampFormatter.detailTimestamp(for: item, locale: Locale(identifier: "ko_KR"))

        assert(formatted == "2026년 5월 15일 (금) 오전 10:38", "Unexpected timestamp: \(formatted)")
    }

    private static func testUsesItemCustomTitleAndContentPreview() {
        let item = historyItem(
            transcript: "Automatic transcript title\nDetails continue here",
            customTitle: "Manual title"
        )

        let data = NoteListRowDisplayData(item: item, retryingIDs: [])

        assert(data.displayTitle == "Manual title")
        assert(data.preview == "Automatic transcript title\nDetails continue here")
    }

    private static func testDropsAutomaticTitleFromPreview() {
        let item = historyItem(transcript: "Automatic transcript title\nDetails continue here")

        let data = NoteListRowDisplayData(item: item, retryingIDs: [])

        assert(data.displayTitle == "Automatic transcript title")
        assert(data.preview == "Details continue here", "Unexpected preview: \(data.preview)")
    }

    private static func testWhitespaceOnlyCustomTitleDoesNotForceContentPreview() {
        let item = historyItem(
            transcript: "Automatic transcript title\nDetails continue here",
            customTitle: "  \n  "
        )

        let data = NoteListRowDisplayData(item: item, retryingIDs: [])

        assert(data.displayTitle == "Automatic transcript title")
        assert(data.preview == "Details continue here", "Unexpected preview: \(data.preview)")
    }

    private static func testLegacyFailurePreviewUsesSafeMessage() {
        let item = historyItem(
            transcript: "Ignored transcript",
            postProcessingStatus: "Error: Network unavailable"
        )

        let data = NoteListRowDisplayData(item: item, retryingIDs: [])

        assert(data.status == .fail)
        assert(data.preview == "Couldn't transcribe", "Unexpected preview: \(data.preview)")
        assert(!data.preview.contains("Network unavailable"))
    }

    private static func testLegacyFailurePreviewHandlesMissingSpaceAfterPrefix() {
        let item = historyItem(
            transcript: "Ignored transcript",
            postProcessingStatus: "Error:Network unavailable"
        )

        let data = NoteListRowDisplayData(item: item, retryingIDs: [])

        assert(data.status == .fail)
        assert(
            data.preview == "Couldn't transcribe",
            "Unexpected failure preview: \(data.preview)"
        )
        assert(!data.preview.contains("Network unavailable"))
    }

    private static func testRecoveredRecordingUsesFriendlyStatusAndPreview() {
        let item = historyItem(
            transcript: "",
            postProcessingStatus: PipelineHistoryItem.recoveredRecordingStatus
        )

        let data = NoteListRowDisplayData(item: item, retryingIDs: [])

        assert(data.status == .recovered)
        assert(data.displayTitle == "Recording interrupted")
        assert(data.preview == "Recovered after an unexpected shutdown. Not yet transcribed.")
    }

    private static func testDegradedRecoveredRecordingNamesAvailableSource() {
        let cases: [(RecoveredRecordingMode, String, String)] = [
            (
                .microphoneOnly,
                "Microphone audio recovered",
                "System Audio could not be recovered. Microphone audio is available for playback or transcription."
            ),
            (
                .systemAudioOnly,
                "System Audio recovered",
                "Microphone audio could not be recovered. System Audio is available for playback or transcription."
            ),
            (
                .partial,
                "Some audio recovered",
                "Some parts of this recording may be missing. The recovered audio is available for playback or transcription."
            )
        ]
        for (mode, title, preview) in cases {
            let item = historyItem(
                transcript: "",
                postProcessingStatus: mode.recoveredStatus
            )
            let data = NoteListRowDisplayData(item: item, retryingIDs: [])

            assert(data.status == .recovered)
            assert(data.displayTitle == title)
            assert(data.preview == preview)
        }
    }

    private static func testStorageInterruptionPreviewCombinesCauseAndMode() {
        let complete = RecoveredRecordingContext(
            mode: .complete,
            interruptionReason: .storageFull
        )
        let completeData = NoteListRowDisplayData(
            item: historyItem(
                transcript: "",
                postProcessingStatus: complete.recoveredStatus
            ),
            retryingIDs: []
        )
        assert(completeData.displayTitle == "Recording stopped: storage full")
        assert(
            completeData.preview == "Quill stopped recording because storage was full. Audio saved before the interruption is available for playback or transcription."
        )

        let partial = RecoveredRecordingContext(
            mode: .partial,
            interruptionReason: .storageFull
        )
        let partialData = NoteListRowDisplayData(
            item: historyItem(
                transcript: "",
                postProcessingStatus: partial.recoveredStatus
            ),
            retryingIDs: []
        )
        assert(partialData.displayTitle == "Recording stopped: storage full")
        assert(
            partialData.preview == "Quill stopped recording because storage was full. Some parts of this recording may be missing. The recovered audio is available for playback or transcription."
        )
    }

    private static func testTranscribingTitleAndEmptyPreview() {
        let id = UUID()
        let item = historyItem(id: id, transcript: "", postProcessingStatus: "importing")

        let data = NoteListRowDisplayData(item: item, retryingIDs: [id])

        assert(data.status == .transcribing)
        // The row names the note; the stage text lives in the note detail.
        // A note being retried keeps its own name rather than "New Recording".
        assert(data.displayTitle != "New Recording")
        assert(data.preview.isEmpty)

        let importing = NoteListRowDisplayData(
            item: historyItem(transcript: "", postProcessingStatus: "importing"),
            retryingIDs: []
        )
        assert(importing.displayTitle == "Imported Audio")

        // A cloud-transcribed import has the cloud status, not "importing" (#386).
        let cloudImport = NoteListRowDisplayData(
            item: historyItem(
                transcript: "",
                postProcessingStatus: PipelineHistoryItem.cloudTranscribingStatus,
                debugStatus: PipelineHistoryItem.importingDebugStatus
            ),
            retryingIDs: []
        )
        assert(cloudImport.displayTitle == "Imported Audio", "Unexpected title: \(cloudImport.displayTitle)")

        // A cloud-transcribed recording is still a new recording.
        let cloudRecording = NoteListRowDisplayData(
            item: historyItem(
                transcript: "",
                postProcessingStatus: PipelineHistoryItem.cloudTranscribingStatus
            ),
            retryingIDs: []
        )
        assert(cloudRecording.displayTitle == "New Recording")
    }

    /// VoiceOver hears the state in words, not only the dot's color (#389).
    private static func testRowAccessibilityLabelSpellsOutState() {
        let identity: (String) -> String = { $0 }
        let failed = NoteListRowAccessibility.label(
            title: "New Recording",
            date: "Sep 27, 7:34 PM",
            status: .fail,
            hasSummary: false,
            selection: nil,
            localize: identity
        )
        assert(failed == "New Recording, Sep 27, 7:34 PM, Transcription failed", failed)

        let done = NoteListRowAccessibility.label(
            title: "Weekly sync",
            date: "Sep 27, 4:56 PM",
            status: .done,
            hasSummary: true,
            selection: .checked,
            localize: identity
        )
        assert(done == "Weekly sync, Sep 27, 4:56 PM, Transcription complete, Summary, Selected", done)

        let busy = NoteListRowAccessibility.label(
            title: "New Recording",
            date: "Sep 27, 7:40 PM",
            status: .recording,
            hasSummary: false,
            selection: .unavailable,
            localize: identity
        )
        assert(busy.hasSuffix("Can't be selected while recording or processing"), busy)
        assert(NoteListRowAccessibility.statusKey(for: .done) != NoteListRowAccessibility.statusKey(for: .fail))

        // A recording that could not be recovered is read as such (#254).
        let unrecovered = NoteListRowAccessibility.label(
            title: "New Recording",
            date: "Sep 27, 7:34 PM",
            status: .fail,
            hasSummary: false,
            selection: nil,
            isUnrecoveredRecording: true,
            localize: identity
        )
        assert(unrecovered == "New Recording, Sep 27, 7:34 PM, Couldn't recover", unrecovered)
    }

    private static func testPostProcessingNoteShowsPostProcessingTitle() {
        let id = UUID()
        let item = historyItem(
            id: id,
            transcript: "",
            postProcessingStatus: PipelineHistoryItem.transcriptionRecoveryPlaceholderStatus
        )

        let transcribing = NoteListRowDisplayData(item: item, retryingIDs: [])
        assert(transcribing.displayTitle == "New Recording")
        assert(transcribing.preview.isEmpty)
    }

    /// A retried note keeps its resting name in the list; the spinner and
    /// the note detail show the stage (#387).
    private static func testRetriedNoteKeepsItsNameInsteadOfTheStage() {
        let stageTitles = ["Transcribing...", "Post-processing..."]

        let audioOnly = PipelineHistoryItem.audioOnly(
            timestamp: Date(timeIntervalSince1970: 10),
            recordingStartedAt: Date(timeIntervalSince1970: 1),
            recordingEndedAt: Date(timeIntervalSince1970: 10),
            calendarMatch: nil,
            audioFileName: "recording.wav",
            transcriptionLanguageCode: "auto",
            localTranscriptionModelID: "remembered-model"
        )
        let retriedAudioOnly = NoteListRowDisplayData(item: audioOnly, retryingIDs: [audioOnly.id])
        assert(retriedAudioOnly.status == .transcribing)
        assert(
            retriedAudioOnly.displayTitle == "Audio recording",
            "Unexpected title: \(retriedAudioOnly.displayTitle)"
        )

        let failedID = UUID()
        let failed = historyItem(
            id: failedID,
            transcript: "",
            postProcessingStatus: QuillUserIssueRecord(code: .localTranscriptionFailed).persistedStatus
        )
        let retriedFailed = NoteListRowDisplayData(item: failed, retryingIDs: [failedID])
        assert(retriedFailed.status == .transcribing)
        assert(
            retriedFailed.displayTitle == "New Recording",
            "Unexpected title: \(retriedFailed.displayTitle)"
        )

        let titledID = UUID()
        let titled = historyItem(id: titledID, transcript: "", customTitle: "Design review")
        let retriedTitled = NoteListRowDisplayData(item: titled, retryingIDs: [titledID])
        assert(retriedTitled.displayTitle == "Design review")

        let withTextID = UUID()
        let withText = historyItem(id: withTextID, transcript: "Weekly sync\nNotes follow")
        let retriedWithText = NoteListRowDisplayData(item: withText, retryingIDs: [withTextID])
        assert(retriedWithText.displayTitle == "Weekly sync")

        for data in [retriedAudioOnly, retriedFailed, retriedTitled, retriedWithText] {
            assert(!stageTitles.contains(data.displayTitle), "Row must not name the stage")
        }
    }

    private static func testOnlyFinishedNotesAreBulkSelectable() {
        assert(TranscriptStatus.done.isBulkSelectable)
        assert(TranscriptStatus.audioOnly.isBulkSelectable)
        assert(TranscriptStatus.recovered.isBulkSelectable)
        assert(TranscriptStatus.fail.isBulkSelectable)
        assert(!TranscriptStatus.recording.isBulkSelectable)
        assert(!TranscriptStatus.transcribing.isBulkSelectable)
    }

    private static func testCloudChunkProgressDisplaysActiveChunk() {
        let id = UUID()
        let item = historyItem(
            id: id,
            transcript: "",
            postProcessingStatus: PipelineHistoryItem.cloudTranscribingStatus
        )
        let progress = CloudTranscriptionDisplayProgress(
            completedChunkCount: 2,
            totalChunkCount: 7,
            activeAttempt: 1
        )

        let data = NoteListRowDisplayData(
            item: item,
            retryingIDs: [],
            cloudProgress: progress,
            localization: { key, arguments in
                key == "Transcribing %d of %d…"
                    ? String(format: key, arguments: arguments)
                    : key
            }
        )

        assert(data.status == .transcribing)
        assert(data.displayTitle == "New Recording")
        // Chunk progress is shown in the note detail only.
        assert(data.preview.isEmpty, "Unexpected progress: \(data.preview)")
    }

    private static func testRestoredCloudProgressDisplaysWaitingCopy() {
        let item = historyItem(
            transcript: "",
            postProcessingStatus: PipelineHistoryItem.cloudTranscribingStatus
        )
        let progress = CloudTranscriptionDisplayProgress(
            completedChunkCount: 2,
            totalChunkCount: 7,
            activeAttempt: nil
        )

        let data = NoteListRowDisplayData(
            item: item,
            retryingIDs: [],
            cloudProgress: progress,
            localization: { key, _ in key }
        )

        assert(data.preview.isEmpty)
    }

    private static func testCloudProgressCopyLocalizesInKorean() {
        let item = historyItem(
            transcript: "",
            postProcessingStatus: PipelineHistoryItem.cloudTranscribingStatus
        )
        let progress = CloudTranscriptionDisplayProgress(
            completedChunkCount: 2,
            totalChunkCount: 7,
            activeAttempt: 2
        )
        let translations = [
            "Transcribing %d of %d…": "%d/%d 청크 전사 중…",
            "Resuming cloud transcription…": "클라우드 전사 재개 중…"
        ]

        let data = NoteListRowDisplayData(
            item: item,
            retryingIDs: [],
            cloudProgress: progress,
            localization: { key, arguments in
                String(
                    format: translations[key] ?? key,
                    locale: Locale(identifier: "ko"),
                    arguments: arguments
                )
            }
        )

        assert(data.preview.isEmpty)
    }

    private static func testRetryingItemHidesExistingPreview() {
        let id = UUID()
        let item = historyItem(id: id, transcript: "Previous title\nPrevious content")

        let data = NoteListRowDisplayData(item: item, retryingIDs: [id])

        assert(data.status == .transcribing)
        assert(data.preview.isEmpty, "Expected retrying item to hide stale preview, got: \(data.preview)")
    }

    private static func testAudioOnlyRowUsesBlueStateAndNotTranscribedPreview() {
        let item = PipelineHistoryItem.audioOnly(
            timestamp: Date(timeIntervalSince1970: 10),
            recordingStartedAt: Date(timeIntervalSince1970: 1),
            recordingEndedAt: Date(timeIntervalSince1970: 10),
            calendarMatch: nil,
            audioFileName: "recording.wav",
            transcriptionLanguageCode: "auto",
            localTranscriptionModelID: "remembered-model"
        )
        let data = NoteListRowDisplayData(
            item: item,
            retryingIDs: [],
            localization: { key, _ in key }
        )

        assert(data.status == .audioOnly)
        assert(data.displayTitle == "Audio recording")
        assert(data.preview == "Not transcribed")
        assert(transcriptStatus(for: item, retrying: [item.id]) == .transcribing)
    }

    private static func historyItem(
        id: UUID = UUID(),
        timestamp: Date = Date(timeIntervalSince1970: 1),
        recordingStartedAt: Date? = nil,
        recordingEndedAt: Date? = nil,
        transcript: String,
        postProcessingStatus: String = "Post-processing succeeded",
        debugStatus: String = "Done",
        customTitle: String? = nil,
        meetingSummaryJSON: Data? = nil
    ) -> PipelineHistoryItem {
        PipelineHistoryItem(
            id: id,
            timestamp: timestamp,
            recordingStartedAt: recordingStartedAt,
            recordingEndedAt: recordingEndedAt,
            rawTranscript: transcript,
            postProcessedTranscript: transcript,
            postProcessingPrompt: nil,
            contextSummary: "",
            contextPrompt: nil,
            contextScreenshotDataURL: nil,
            contextScreenshotStatus: "No screenshot",
            postProcessingStatus: postProcessingStatus,
            debugStatus: debugStatus,
            customVocabulary: "",
            customTitle: customTitle,
            meetingSummaryJSON: meetingSummaryJSON
        )
    }

    private static func date(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int,
        timeZone: TimeZone = .current
    ) -> Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = timeZone
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return components.date!
    }
}

private final class LockedStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}
