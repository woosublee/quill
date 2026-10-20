import Foundation

@main
struct NoteTitleResolutionTests {
    static func main() {
        testItemCustomTitleWins()
        testAppliedCalendarTitleWinsOverTranscriptTitle()
        testSuggestedCalendarTitleDoesNotOverrideTranscriptTitle()
        testFallbackUsedWhenNoContentOrAppliedCalendarTitle()
        testTranscribingFallbackWinsOverFailedEmptyContent()
        testAppliedCalendarTitleKeepsWinningWhileTranscribing()
        testPostProcessingTitleWhileTranscribing()
        testProcessingTitlesAreLocalized()
        testCalendarAppliedTitleIncludesRecordingDate()
        testRecoveredRecordingTitlesNameAvailableSource()
        testStorageInterruptionReasonWinsRecoveredTitle()
        testAudioOnlyTitleUsesNormalPrecedence()
        testSuggestedCalendarTitleShownEvenWhenTranscriptReadsLikeIt()
        testSuggestedCalendarTitleTreatsWhitespaceTitleAsNone()
        testDateTitleUsesRecordingStartAndLocale()
        testToolTitleKeepsTheTranscriptsFirstLine()
        testSuggestedCalendarTitleShownWhenItWouldChangeTheTitle()
        testOutsideTitleChangeReplacesTheDraft()
        testOutsideTitleChangeKeepsAnUnsavedEdit()
        testOutsideTitleChangeMatchingTheDraftChangesNothing()
        testTypedTitleIsSavedTrimmedAndNilWhenEmpty()
        print("NoteTitleResolutionTests passed")
    }

    private static func testItemCustomTitleWins() {
        let item = item(
            transcript: "Transcript title",
            calendarMatch: match(title: "Calendar title", titleState: .applied),
            customTitle: "Manual title"
        )
        let title = NoteTitleResolver.displayTitle(for: item)
        assert(title == "Manual title")
    }

    private static func testAppliedCalendarTitleWinsOverTranscriptTitle() {
        let item = item(transcript: "Transcript title", calendarMatch: match(title: "Calendar title", titleState: .applied))
        let title = NoteTitleResolver.displayTitle(for: item)
        assert(title == "Calendar title")
    }

    private static func testSuggestedCalendarTitleDoesNotOverrideTranscriptTitle() {
        let item = item(transcript: "Transcript title", calendarMatch: match(title: "Calendar title", titleState: .suggested))
        let title = NoteTitleResolver.displayTitle(for: item)
        // An untitled note is named by when it was recorded, as its detail
        // placeholder and the iPhone app show it.
        assert(title == NoteTitleResolver.dateTitle(for: Date(timeIntervalSince1970: 1)))
    }

    private static func testFallbackUsedWhenNoContentOrAppliedCalendarTitle() {
        let item = item(transcript: "", calendarMatch: nil)
        let title = NoteTitleResolver.displayTitle(for: item)
        assert(title == NoteTitleResolver.dateTitle(for: Date(timeIntervalSince1970: 1)))
    }

    private static func testTranscribingFallbackWinsOverFailedEmptyContent() {
        let item = item(transcript: "", calendarMatch: nil, postProcessingStatus: "Error: Previous failure")
        let title = NoteTitleResolver.displayTitle(for: item, isTranscribing: true)
        assert(title == "Transcribing...")
    }

    private static func testPostProcessingTitleWhileTranscribing() {
        let item = item(transcript: "", calendarMatch: nil)
        let title = NoteTitleResolver.displayTitle(
            for: item,
            isTranscribing: true,
            isPostProcessing: true
        )
        assert(title == "Post-processing...")
        // Post-processing only labels a note that is still being processed.
        assert(NoteTitleResolver.displayTitle(for: item, isPostProcessing: true) == NoteTitleResolver.dateTitle(for: Date(timeIntervalSince1970: 1)))
    }

    private static func testProcessingTitlesAreLocalized() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-note-title-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let localizationDirectory = root.appendingPathComponent("ko.lproj", isDirectory: true)
        try! FileManager.default.createDirectory(at: localizationDirectory, withIntermediateDirectories: true)
        try! """
        "Transcribing..." = "전사 중...";
        "Post-processing..." = "후처리 중...";
        "Recording..." = "녹음 중...";
        """.write(
            to: localizationDirectory.appendingPathComponent("Localizable.strings"),
            atomically: true,
            encoding: .utf8
        )
        let bundle = Bundle(path: root.path)!
        let empty = item(transcript: "", calendarMatch: nil)

        assert(NoteTitleResolver.displayTitle(for: empty, isTranscribing: true, language: "ko", bundle: bundle) == "전사 중...")
        assert(NoteTitleResolver.displayTitle(for: empty, isTranscribing: true, isPostProcessing: true, language: "ko", bundle: bundle) == "후처리 중...")
        let placeholder = item(
            transcript: "",
            calendarMatch: nil,
            postProcessingStatus: PipelineHistoryItem.transcriptionRecoveryPlaceholderStatus
        )
        assert(NoteTitleResolver.displayTitle(for: placeholder, language: "ko", bundle: bundle) == "전사 중...")
        let live = item(transcript: "", calendarMatch: nil, postProcessingStatus: "live-recording")
        assert(NoteTitleResolver.displayTitle(for: live, language: "ko", bundle: bundle) == "녹음 중...")
    }

    private static func testAppliedCalendarTitleKeepsWinningWhileTranscribing() {
        let item = item(transcript: "", calendarMatch: match(title: "Calendar title", titleState: .applied), postProcessingStatus: "Error: Previous failure")
        let title = NoteTitleResolver.displayTitle(for: item, isTranscribing: true)
        assert(title == "Calendar title")
    }

    private static func testCalendarAppliedTitleIncludesRecordingDate() {
        let recordingStartedAt = Date(timeIntervalSince1970: 1_746_422_400)
        let title = NoteTitleResolver.calendarAppliedTitle(
            suggestedTitle: "Team Standup",
            recordingStartedAt: recordingStartedAt
        )
        assert(title == "2025-05-05 Team Standup")
    }

    private static func testRecoveredRecordingTitlesNameAvailableSource() {
        let cases: [(RecoveredRecordingMode, String)] = [
            (.complete, "Recording interrupted"),
            (.microphoneOnly, "Microphone audio recovered"),
            (.systemAudioOnly, "System Audio recovered"),
            (.partial, "Some audio recovered")
        ]
        for (mode, expected) in cases {
            let recovered = item(
                transcript: "",
                calendarMatch: nil,
                postProcessingStatus: mode.recoveredStatus
            )
            assert(NoteTitleResolver.displayTitle(for: recovered) == expected)
        }
    }

    private static func testStorageInterruptionReasonWinsRecoveredTitle() {
        let cases: [(RecordingInterruptionReason, String)] = [
            (.storageFull, "Recording stopped: storage full"),
            (.permissionDenied, "Recording stopped: storage unavailable"),
            (.journalIOFailure, "Recording stopped: save error")
        ]
        for (reason, expected) in cases {
            let context = RecoveredRecordingContext(
                mode: .partial,
                interruptionReason: reason
            )
            let recovered = item(
                transcript: "",
                calendarMatch: nil,
                postProcessingStatus: context.recoveredStatus
            )
            assert(NoteTitleResolver.displayTitle(for: recovered) == expected)
        }
    }

    private static func testAudioOnlyTitleUsesNormalPrecedence() {
        let audioOnly = PipelineHistoryItem.audioOnly(
            timestamp: Date(timeIntervalSince1970: 10),
            recordingStartedAt: Date(timeIntervalSince1970: 1),
            recordingEndedAt: Date(timeIntervalSince1970: 10),
            calendarMatch: nil,
            audioFileName: "recording.wav",
            transcriptionLanguageCode: "auto",
            localTranscriptionModelID: "remembered-model"
        )
        // Its row preview says "Not transcribed"; the name is when its
        // recording started, as the row's date reads it.
        assert(NoteTitleResolver.displayTitle(for: audioOnly) == NoteTitleResolver.dateTitle(for: Date(timeIntervalSince1970: 1)))

        let calendarMatch = CalendarEventMatch(
            calendarID: "calendar",
            eventID: "event",
            title: "Weekly Sync",
            start: Date(timeIntervalSince1970: 1),
            end: Date(timeIntervalSince1970: 10),
            matchSource: .overlapSuggestion,
            titleState: .applied
        )
        let calendar = PipelineHistoryItem.audioOnly(
            timestamp: Date(timeIntervalSince1970: 10),
            recordingStartedAt: Date(timeIntervalSince1970: 1),
            recordingEndedAt: Date(timeIntervalSince1970: 10),
            calendarMatch: calendarMatch,
            audioFileName: "recording.wav",
            transcriptionLanguageCode: "auto",
            localTranscriptionModelID: "remembered-model"
        )
        assert(NoteTitleResolver.displayTitle(for: calendar) == "Weekly Sync")
        assert(
            NoteTitleResolver.displayTitle(
                for: audioOnly.withCustomTitle("My recording")
            ) == "My recording"
        )
    }

    // An untitled note is named by its date, so a transcript that happens
    // to read like the applied title doesn't count as that title: the
    // suggestion is offered.
    private static func testSuggestedCalendarTitleShownEvenWhenTranscriptReadsLikeIt() {
        let appliedTitle = NoteTitleResolver.calendarAppliedTitle(
            suggestedTitle: "Team Standup",
            recordingStartedAt: Date(timeIntervalSince1970: 1)
        )
        let note = item(
            transcript: appliedTitle,
            calendarMatch: match(title: "Team Standup", titleState: .suggested)
        )
        assert(NoteTitleResolver.suggestedCalendarTitle(for: note)?.applied == appliedTitle)
    }

    // A whitespace-only title counts as none, as everywhere else; a padded
    // real title is the note's own and hides the suggestion.
    private static func testSuggestedCalendarTitleTreatsWhitespaceTitleAsNone() {
        let blank = item(
            transcript: "Synthetic transcript",
            calendarMatch: match(title: "Team Standup", titleState: .suggested),
            customTitle: "   "
        )
        assert(NoteTitleResolver.suggestedCalendarTitle(for: blank)?.suggested == "Team Standup")
        let titled = item(
            transcript: "Synthetic transcript",
            calendarMatch: match(title: "Team Standup", titleState: .suggested),
            customTitle: "  Planning  "
        )
        assert(NoteTitleResolver.suggestedCalendarTitle(for: titled) == nil)
    }

    private static func testDateTitleUsesRecordingStartAndLocale() {
        var note = item(transcript: "Synthetic transcript", calendarMatch: nil)
        let saved = NoteTitleResolver.displayTitle(for: note)
        assert(saved == NoteTitleResolver.dateTitle(for: Date(timeIntervalSince1970: 1)))
        note = PipelineHistoryItem(
            timestamp: Date(timeIntervalSince1970: 7_200),
            recordingStartedAt: Date(timeIntervalSince1970: 3_600),
            rawTranscript: "Synthetic transcript",
            postProcessedTranscript: "Synthetic transcript",
            postProcessingPrompt: nil,
            contextSummary: "",
            contextScreenshotDataURL: nil,
            contextScreenshotStatus: "No screenshot",
            postProcessingStatus: "Post-processing succeeded",
            debugStatus: "Done",
            customVocabulary: ""
        )
        assert(NoteTitleResolver.displayTitle(for: note) == NoteTitleResolver.dateTitle(for: Date(timeIntervalSince1970: 3_600)), "the recording's start, as the row's date")
        let korean = NoteTitleResolver.displayTitle(for: note, locale: Locale(identifier: "ko_KR"))
        assert(korean == NoteTitleResolver.dateTitle(for: Date(timeIntervalSince1970: 3_600), locale: Locale(identifier: "ko_KR")))
        assert(korean != NoteTitleResolver.dateTitle(for: Date(timeIntervalSince1970: 3_600), locale: Locale(identifier: "en_US")), "the row's locale decides")
        assert(NoteTitleResolver.isNamedByDate(note))
        let live = item(transcript: "", calendarMatch: nil, postProcessingStatus: "live-recording")
        assert(!NoteTitleResolver.isNamedByDate(live), "a note being recorded keeps its state name")
    }

    /// AI tools (MCP) keep telling notes apart by their content.
    private static func testToolTitleKeepsTheTranscriptsFirstLine() {
        let note = item(transcript: "\n  Weekly sync  \nNotes follow", calendarMatch: nil)
        assert(NoteTitleResolver.toolTitle(for: note) == "Weekly sync")
        let titled = item(transcript: "Weekly sync", calendarMatch: nil, customTitle: "Planning")
        assert(NoteTitleResolver.toolTitle(for: titled) == "Planning")
        // Without a transcript, tools keep the names they always got.
        let empty = item(transcript: "", calendarMatch: nil)
        assert(NoteTitleResolver.toolTitle(for: empty) == "(No content)")
        let failed = item(transcript: "", calendarMatch: nil, postProcessingStatus: "Error: Previous failure")
        assert(NoteTitleResolver.toolTitle(for: failed) == "New Recording")
        let audioOnly = PipelineHistoryItem.audioOnly(
            timestamp: Date(timeIntervalSince1970: 10),
            recordingStartedAt: Date(timeIntervalSince1970: 1),
            recordingEndedAt: Date(timeIntervalSince1970: 10),
            calendarMatch: nil,
            audioFileName: "recording.wav",
            transcriptionLanguageCode: "auto",
            localTranscriptionModelID: "remembered-model"
        )
        assert(NoteTitleResolver.toolTitle(for: audioOnly) == "Audio recording")
    }

    private static func testSuggestedCalendarTitleShownWhenItWouldChangeTheTitle() {
        let note = item(
            transcript: "Unrelated transcript content",
            calendarMatch: match(title: "Team Standup", titleState: .suggested)
        )
        assert(NoteTitleResolver.suggestedCalendarTitle(for: note)?.suggested == "Team Standup")
    }

    private static func testOutsideTitleChangeReplacesTheDraft() {
        assert(NoteTitleResolver.titleDraftAfterOutsideChange(
            draft: "Old title", newTitle: "Title from another Mac", hasUnsavedEdit: false
        ) == "Title from another Mac")
        // A title cleared on another Mac clears the field.
        assert(NoteTitleResolver.titleDraftAfterOutsideChange(
            draft: "Old title", newTitle: nil, hasUnsavedEdit: false
        ) == "")
    }

    private static func testOutsideTitleChangeKeepsAnUnsavedEdit() {
        assert(NoteTitleResolver.titleDraftAfterOutsideChange(
            draft: "Typing here", newTitle: "Title from another Mac", hasUnsavedEdit: true
        ) == nil)
    }

    private static func testOutsideTitleChangeMatchingTheDraftChangesNothing() {
        // This Mac's own save comes back as the same title.
        assert(NoteTitleResolver.titleDraftAfterOutsideChange(
            draft: "Same", newTitle: "Same", hasUnsavedEdit: false
        ) == nil)
        assert(NoteTitleResolver.titleDraftAfterOutsideChange(
            draft: "", newTitle: nil, hasUnsavedEdit: false
        ) == nil)
        // The save trims, so a space typed between words survives it.
        assert(NoteTitleResolver.titleDraftAfterOutsideChange(
            draft: "Team ", newTitle: "Team", hasUnsavedEdit: false
        ) == nil)
        assert(NoteTitleResolver.titleDraftAfterOutsideChange(
            draft: "   ", newTitle: nil, hasUnsavedEdit: false
        ) == nil)
    }

    private static func testTypedTitleIsSavedTrimmedAndNilWhenEmpty() {
        assert(NoteTitleResolver.normalizedCustomTitle("  Team sync \n") == "Team sync")
        assert(NoteTitleResolver.normalizedCustomTitle("   ") == nil)
        assert(NoteTitleResolver.normalizedCustomTitle("") == nil)
    }

    private static func item(
        transcript: String,
        calendarMatch: CalendarEventMatch?,
        postProcessingStatus: String = "Post-processing succeeded",
        customTitle: String? = nil
    ) -> PipelineHistoryItem {
        PipelineHistoryItem(
            timestamp: Date(timeIntervalSince1970: 1),
            calendarMatch: calendarMatch,
            rawTranscript: transcript,
            postProcessedTranscript: transcript,
            postProcessingPrompt: nil,
            contextSummary: "",
            contextPrompt: nil,
            contextScreenshotDataURL: nil,
            contextScreenshotStatus: "No screenshot",
            postProcessingStatus: postProcessingStatus,
            debugStatus: "Done",
            customVocabulary: "",
            customTitle: customTitle
        )
    }

    private static func match(title: String, titleState: CalendarTitleState) -> CalendarEventMatch {
        CalendarEventMatch(calendarID: "calendar", eventID: "event", title: title, start: Date(timeIntervalSince1970: 1), end: Date(timeIntervalSince1970: 2), matchSource: .overlapSuggestion, titleState: titleState)
    }
}
