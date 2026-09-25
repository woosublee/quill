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
        testSuggestedCalendarTitleHiddenWhenAlreadyEffectivelyApplied()
        testSuggestedCalendarTitleHiddenWhenOnlyWhitespaceDiffers()
        testSuggestedCalendarTitleShownWhenItWouldChangeTheTitle()
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
        assert(title == "Transcript title")
    }

    private static func testFallbackUsedWhenNoContentOrAppliedCalendarTitle() {
        let item = item(transcript: "", calendarMatch: nil)
        let title = NoteTitleResolver.displayTitle(for: item)
        assert(title == "(No content)")
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
        assert(NoteTitleResolver.displayTitle(for: item, isPostProcessing: true) == "(No content)")
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
        assert(NoteTitleResolver.displayTitle(for: audioOnly) == "Audio recording")

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

    // Applying the suggestion would set the effective title to exactly what
    // is already shown (the transcript-derived title happens to match), so
    // the banner offering that suggestion must not appear.
    private static func testSuggestedCalendarTitleHiddenWhenAlreadyEffectivelyApplied() {
        let recordingStartedAt = Date(timeIntervalSince1970: 1)
        let appliedTitle = NoteTitleResolver.calendarAppliedTitle(
            suggestedTitle: "Team Standup",
            recordingStartedAt: recordingStartedAt
        )
        let note = item(
            transcript: appliedTitle,
            calendarMatch: match(title: "Team Standup", titleState: .suggested)
        )
        assert(NoteTitleResolver.suggestedCalendarTitle(for: note) == nil)
    }

    // displayTitle(for:) trims the transcript-derived title, so a match that
    // is only different by leading/trailing whitespace must still count as
    // already applied and hide the banner.
    private static func testSuggestedCalendarTitleHiddenWhenOnlyWhitespaceDiffers() {
        let recordingStartedAt = Date(timeIntervalSince1970: 1)
        let appliedTitle = NoteTitleResolver.calendarAppliedTitle(
            suggestedTitle: "Team Standup",
            recordingStartedAt: recordingStartedAt
        )
        let note = item(
            transcript: "  \(appliedTitle)  ",
            calendarMatch: match(title: "Team Standup", titleState: .suggested)
        )
        assert(NoteTitleResolver.suggestedCalendarTitle(for: note) == nil)
    }

    private static func testSuggestedCalendarTitleShownWhenItWouldChangeTheTitle() {
        let note = item(
            transcript: "Unrelated transcript content",
            calendarMatch: match(title: "Team Standup", titleState: .suggested)
        )
        assert(NoteTitleResolver.suggestedCalendarTitle(for: note)?.suggested == "Team Standup")
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
