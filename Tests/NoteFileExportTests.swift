import Foundation

@main
struct NoteFileExportTests {
    static func main() throws {
        try testLongSummaryNameDoesNotPartiallyExport()
        try testFileNameValidationIncludesSuffixAndExtension()
        try testMaximumLengthSummaryNamesExport()
        try testTooLongSummaryOnlyDoesNotCreateFile()
        try testSanitizedBaseNameAndFallback()
        try testSuggestedBaseNamePrefersTitle()
        try testSuggestedBaseNameFallsBackToCalendarTitle()
        try testSuggestedBaseNameUsesLocalizedTimestamp()
        try testLocalizedTimestampNameExportsWithColon()
        try testDestinationNamesPreserveAudioExtension()
        try testExportsTranscriptAndAudio()
        try testConflictDoesNotOverwriteWithoutConsent()
        try testPreparedFileReportsLateConflict()
        try testReplaceOverwritesExistingFile()
        try testPartialFailureKeepsSuccessfulTranscript()
        testSummaryAvailability()
        testSummaryStalenessRequiresAvailableSummary()
        try testExportsSummaryWithoutOtherItems()
        try testExportsAllItemsWithoutColliding()
        try testUnselectedSummaryIsNotExported()
        try testSummaryConflictRequiresConsent()
        try testMissingSummaryKeepsSuccessfulTranscript()
        print("NoteFileExportTests passed")
    }

    private static func testLongSummaryNameDoesNotPartiallyExport() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let baseName = String(repeating: "a", count: 244)
        let existingTranscript = root.appendingPathComponent(baseName + ".txt")
        try "기존 전사문".write(to: existingTranscript, atomically: true, encoding: .utf8)
        let request = NoteFileExportRequest(
            source: NoteFileExportSource(
                transcript: "새 전사문",
                audioURL: nil,
                summary: "요약"
            ),
            selectedItems: [.transcript, .summary],
            textFormat: .plainText,
            baseName: baseName,
            destinationDirectory: root
        )

        let result = NoteFileExporter.export(request, replaceExisting: true)

        precondition(result.savedItems.isEmpty, "파일명 검증 실패 시 다른 파일도 저장하면 안 됩니다.")
        precondition(result.failures.map(\.item) == [.summary])
        let unchanged = try String(contentsOf: existingTranscript, encoding: .utf8)
        precondition(unchanged == "기존 전사문")
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
        precondition(files == [baseName + ".txt"])
    }

    private static func testFileNameValidationIncludesSuffixAndExtension() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = NoteFileExportSource(
            transcript: "전사문",
            audioURL: root.appendingPathComponent("source.aiff"),
            summary: "요약"
        )
        let cases: [(String, NoteFileExportTextFormat, Set<NoteFileExportItem>, Set<NoteFileExportItem>)] = [
            (String(repeating: "a", count: 243), .plainText, [.transcript, .summary], []),
            (String(repeating: "a", count: 244), .plainText, [.transcript, .summary], [.summary]),
            (String(repeating: "a", count: 244), .markdown, [.transcript, .summary], []),
            (String(repeating: "a", count: 244), .plainText, [.transcript], []),
            (String(repeating: "a", count: 252), .plainText, [.transcript], [.transcript]),
            (String(repeating: "a", count: 250), .plainText, [.audio], []),
            (String(repeating: "a", count: 251), .plainText, [.audio], [.audio]),
            (String(repeating: "가", count: 121), .plainText, [.summary], []),
            (String(repeating: "가", count: 122), .plainText, [.summary], [.summary]),
            (String(repeating: "漢", count: 243), .plainText, [.summary], []),
            (String(repeating: "😀", count: 121), .plainText, [.summary], []),
            (String(repeating: "😀", count: 122), .plainText, [.summary], [.summary]),
            (String(repeating: "e\u{301}", count: 122), .plainText, [.summary], [.summary])
        ]
        for (baseName, format, selected, expectedFailures) in cases {
            let request = NoteFileExportRequest(
                source: source,
                selectedItems: selected,
                textFormat: format,
                baseName: baseName,
                destinationDirectory: root
            )
            let failures = NoteFileExporter.fileNameFailures(for: request)
            precondition(
                Set(failures.map(\.item)) == expectedFailures,
                "UTF16=\(baseName.utf16.count), format=\(format), selected=\(selected), failures=\(failures)"
            )
            precondition(failures.allSatisfy { $0.reason == .fileNameTooLong })
        }
    }

    private static func testMaximumLengthSummaryNamesExport() throws {
        for baseName in [
            String(repeating: "a", count: 243),
            String(repeating: "가", count: 121),
            String(repeating: "漢", count: 243),
            String(repeating: "😀", count: 121)
        ] {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let request = NoteFileExportRequest(
                source: NoteFileExportSource(transcript: "", audioURL: nil, summary: "요약"),
                selectedItems: [.summary],
                textFormat: .plainText,
                baseName: baseName,
                destinationDirectory: root
            )
            let result = NoteFileExporter.export(request, replaceExisting: false)
            precondition(result.isComplete)
            precondition(result.savedItems == [.summary])
            let saved = try String(
                contentsOf: root.appendingPathComponent(baseName + "-summary.txt"),
                encoding: .utf8
            )
            precondition(saved == "요약")
        }
    }

    private static func testTooLongSummaryOnlyDoesNotCreateFile() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let request = NoteFileExportRequest(
            source: NoteFileExportSource(transcript: "", audioURL: nil, summary: "요약"),
            selectedItems: [.summary],
            textFormat: .plainText,
            baseName: String(repeating: "a", count: 244),
            destinationDirectory: root
        )
        let result = NoteFileExporter.export(request, replaceExisting: false)
        precondition(result.savedItems.isEmpty)
        precondition(result.failures == [
            NoteFileExportFailure(item: .summary, reason: .fileNameTooLong)
        ])
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
        precondition(files.isEmpty)
    }

    private static func testSanitizedBaseNameAndFallback() throws {
        precondition(
            NoteFileExporter.sanitizedBaseName(
                "  meeting/a:b?  ",
                fallback: "fallback"
            ) == "meeting-a:b-"
        )
        precondition(
            NoteFileExporter.sanitizedBaseName(
                " /\\*?\"<>| ",
                fallback: "2026년 7월 24일 오전 1:45"
            ) == "2026년 7월 24일 오전 1:45"
        )
    }

    private static let localizedNameTimestamp = Date(
        timeIntervalSince1970: 1_784_825_100
    )
    private static let seoulTimeZone = TimeZone(identifier: "Asia/Seoul")!

    private static func testSuggestedBaseNamePrefersTitle() throws {
        let name = NoteFileExportNaming.suggestedBaseName(
            customTitle: "  Product review  ",
            calendarTitle: "Calendar review",
            timestamp: localizedNameTimestamp,
            locale: Locale(identifier: "ko_KR"),
            timeZone: seoulTimeZone
        )
        precondition(name == "Product review")
    }

    private static func testSuggestedBaseNameFallsBackToCalendarTitle() throws {
        let name = NoteFileExportNaming.suggestedBaseName(
            customTitle: " \n ",
            calendarTitle: "  Product review  ",
            timestamp: localizedNameTimestamp,
            locale: Locale(identifier: "ko_KR"),
            timeZone: seoulTimeZone
        )
        precondition(name == "Product review")
    }

    private static func testSuggestedBaseNameUsesLocalizedTimestamp() throws {
        let korean = NoteFileExportNaming.suggestedBaseName(
            customTitle: " \n ",
            calendarTitle: nil,
            timestamp: localizedNameTimestamp,
            locale: Locale(identifier: "ko_KR"),
            timeZone: seoulTimeZone
        )
        let english = NoteFileExportNaming.suggestedBaseName(
            customTitle: nil,
            calendarTitle: nil,
            timestamp: localizedNameTimestamp,
            locale: Locale(identifier: "en_US"),
            timeZone: seoulTimeZone
        )

        precondition(korean == "2026년 7월 24일 오전 1:45")
        precondition(english == "July 24, 2026 at 1:45 AM")
    }

    private static func testLocalizedTimestampNameExportsWithColon() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceDirectory = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let audio = sourceDirectory.appendingPathComponent("recording.wav")
        try Data([4, 5, 6]).write(to: audio)
        let request = NoteFileExportRequest(
            source: NoteFileExportSource(transcript: "# Transcript", audioURL: audio),
            selectedItems: [.transcript, .audio],
            textFormat: .plainText,
            baseName: "2026년 7월 24일 오전 1:45",
            destinationDirectory: destination
        )

        let result = NoteFileExporter.export(request, replaceExisting: false)

        precondition(Set(result.savedItems) == [.transcript, .audio])
        precondition(result.failures.isEmpty)
        precondition(
            FileManager.default.fileExists(
                atPath: destination
                    .appendingPathComponent("2026년 7월 24일 오전 1:45.txt")
                    .path
            )
        )
        precondition(
            FileManager.default.fileExists(
                atPath: destination
                    .appendingPathComponent("2026년 7월 24일 오전 1:45.wav")
                    .path
            )
        )
    }

    private static func testDestinationNamesPreserveAudioExtension() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("source.m4a")
        try Data([1, 2, 3]).write(to: audio)
        let request = NoteFileExportRequest(
            source: NoteFileExportSource(transcript: "hello", audioURL: audio),
            selectedItems: [.transcript, .audio],
            textFormat: .markdown,
            baseName: "Meeting",
            destinationDirectory: root
        )
        let urls = NoteFileExporter.destinationURLs(for: request)

        precondition(urls[.transcript]?.lastPathComponent == "Meeting.md")
        precondition(urls[.audio]?.lastPathComponent == "Meeting.m4a")
    }

    private static func testExportsTranscriptAndAudio() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceDirectory = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let audio = sourceDirectory.appendingPathComponent("recording.wav")
        try Data([4, 5, 6]).write(to: audio)
        let request = NoteFileExportRequest(
            source: NoteFileExportSource(transcript: "# Transcript", audioURL: audio),
            selectedItems: [.transcript, .audio],
            textFormat: .plainText,
            baseName: "Meeting",
            destinationDirectory: destination
        )

        let result = NoteFileExporter.export(request, replaceExisting: false)

        let transcript = try String(
            contentsOf: destination.appendingPathComponent("Meeting.txt"),
            encoding: .utf8
        )
        let audioData = try Data(
            contentsOf: destination.appendingPathComponent("Meeting.wav")
        )
        precondition(Set(result.savedItems) == [.transcript, .audio])
        precondition(result.failures.isEmpty)
        precondition(transcript == "# Transcript")
        precondition(audioData == Data([4, 5, 6]))
    }

    private static func testConflictDoesNotOverwriteWithoutConsent() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = root.appendingPathComponent("Meeting.txt")
        try "old".write(to: existing, atomically: true, encoding: .utf8)
        let request = NoteFileExportRequest(
            source: NoteFileExportSource(transcript: "new", audioURL: nil),
            selectedItems: [.transcript],
            textFormat: .plainText,
            baseName: "Meeting",
            destinationDirectory: root
        )

        let result = NoteFileExporter.export(request, replaceExisting: false)

        precondition(result.savedItems.isEmpty)
        let existingContent = try String(contentsOf: existing, encoding: .utf8)
        precondition(result.failures == [
            NoteFileExportFailure(item: .transcript, reason: .destinationExists)
        ])
        precondition(existingContent == "old")
    }

    private static func testPreparedFileReportsLateConflict() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let prepared = root.appendingPathComponent("prepared.tmp")
        let destination = root.appendingPathComponent("Meeting.txt")
        try "new".write(to: prepared, atomically: true, encoding: .utf8)
        try "old".write(to: destination, atomically: true, encoding: .utf8)

        do {
            try NoteFileExporter.installPreparedFile(
                prepared,
                at: destination,
                replaceExisting: false
            )
            preconditionFailure("Expected a late destination conflict")
        } catch NoteFileExporter.ExportWriteError.destinationExists {
            // Expected.
        }
        let destinationContent = try String(contentsOf: destination, encoding: .utf8)
        precondition(destinationContent == "old")
    }

    private static func testReplaceOverwritesExistingFile() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = root.appendingPathComponent("Meeting.txt")
        try "old".write(to: existing, atomically: true, encoding: .utf8)
        let request = NoteFileExportRequest(
            source: NoteFileExportSource(transcript: "new", audioURL: nil),
            selectedItems: [.transcript],
            textFormat: .plainText,
            baseName: "Meeting",
            destinationDirectory: root
        )

        let result = NoteFileExporter.export(request, replaceExisting: true)

        let existingContent = try String(contentsOf: existing, encoding: .utf8)
        precondition(result.savedItems == [.transcript])
        precondition(result.failures.isEmpty)
        precondition(existingContent == "new")
    }

    private static func testPartialFailureKeepsSuccessfulTranscript() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let missingAudio = root.appendingPathComponent("missing.wav")
        let request = NoteFileExportRequest(
            source: NoteFileExportSource(transcript: "saved text", audioURL: missingAudio),
            selectedItems: [.transcript, .audio],
            textFormat: .plainText,
            baseName: "Meeting",
            destinationDirectory: root
        )

        let result = NoteFileExporter.export(request, replaceExisting: false)

        precondition(result.savedItems == [.transcript])
        let transcript = try String(
            contentsOf: root.appendingPathComponent("Meeting.txt"),
            encoding: .utf8
        )
        precondition(result.failures == [
            NoteFileExportFailure(item: .audio, reason: .sourceMissing)
        ])
        precondition(transcript == "saved text")
    }

    private static func testSummaryAvailability() {
        for summary in [nil, "", " \n\t "] as [String?] {
            let source = NoteFileExportSource(
                transcript: "전사문",
                audioURL: nil,
                summary: summary
            )
            precondition(source.availableItems == [.transcript])
        }
        let summaryOnly = NoteFileExportSource(
            transcript: " \n ",
            audioURL: nil,
            summary: "# 요약\n- 다음 검토는 금요일"
        )
        precondition(summaryOnly.availableItems == [.summary])
    }

    private static func testSummaryStalenessRequiresAvailableSummary() {
        let cases: [(String?, Bool, Bool)] = [
            ("기존 요약", true, true),
            ("현재 요약", false, false),
            (nil, true, false),
            ("", true, false),
            (" \n ", true, false)
        ]
        for (summary, isStale, expected) in cases {
            let source = NoteFileExportSource(
                transcript: "현재 전사문",
                audioURL: nil,
                summary: summary,
                isSummaryStale: isStale
            )
            precondition(source.isSummaryStale == expected)
        }
    }

    private static func testExportsSummaryWithoutOtherItems() throws {
        for (format, fileName) in [
            (NoteFileExportTextFormat.plainText, "Meeting-summary.txt"),
            (.markdown, "Meeting-summary.md")
        ] {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let summary = "# 요약\n\n- 다음 검토는 금요일\n"
            let request = NoteFileExportRequest(
                source: NoteFileExportSource(
                    transcript: "",
                    audioURL: nil,
                    summary: summary
                ),
                selectedItems: [.summary],
                textFormat: format,
                baseName: "Meeting",
                destinationDirectory: root
            )

            let result = NoteFileExporter.export(request, replaceExisting: false)

            precondition(result.savedItems == [.summary])
            precondition(result.isComplete)
            let contents = try String(
                contentsOf: root.appendingPathComponent(fileName),
                encoding: .utf8
            )
            precondition(contents == summary)
            let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
            precondition(files == [fileName])
        }
    }

    private static func testExportsAllItemsWithoutColliding() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("source.m4a")
        try Data([7, 8, 9]).write(to: audio)
        let source = NoteFileExportSource(
            transcript: "전사문 원문",
            audioURL: audio,
            summary: "# 요약\n- 검토 완료"
        )
        precondition(source.availableItems == [.transcript, .summary, .audio])
        let request = NoteFileExportRequest(
            source: source,
            selectedItems: [.transcript, .summary, .audio],
            textFormat: .markdown,
            baseName: "Meeting",
            destinationDirectory: root
        )
        let urls = NoteFileExporter.destinationURLs(for: request)
        precondition(urls[.transcript]?.lastPathComponent == "Meeting.md")
        precondition(urls[.summary]?.lastPathComponent == "Meeting-summary.md")
        precondition(urls[.audio]?.lastPathComponent == "Meeting.m4a")

        let result = NoteFileExporter.export(request, replaceExisting: false)

        precondition(Set(result.savedItems) == [.transcript, .summary, .audio])
        precondition(result.isComplete)
        let transcript = try String(
            contentsOf: root.appendingPathComponent("Meeting.md"),
            encoding: .utf8
        )
        let summary = try String(
            contentsOf: root.appendingPathComponent("Meeting-summary.md"),
            encoding: .utf8
        )
        let exportedAudio = try Data(contentsOf: root.appendingPathComponent("Meeting.m4a"))
        let originalAudio = try Data(contentsOf: audio)
        precondition(transcript == "전사문 원문")
        precondition(summary == "# 요약\n- 검토 완료")
        precondition(exportedAudio == Data([7, 8, 9]))
        precondition(originalAudio == Data([7, 8, 9]))
    }

    private static func testUnselectedSummaryIsNotExported() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let request = NoteFileExportRequest(
            source: NoteFileExportSource(
                transcript: "전사문 원문",
                audioURL: nil,
                summary: "# 선택하지 않은 요약"
            ),
            selectedItems: [.transcript],
            textFormat: .markdown,
            baseName: "Meeting",
            destinationDirectory: root
        )

        let result = NoteFileExporter.export(request, replaceExisting: false)

        precondition(result.savedItems == [.transcript])
        precondition(result.isComplete)
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
        precondition(files == ["Meeting.md"])
        let transcript = try String(
            contentsOf: root.appendingPathComponent("Meeting.md"),
            encoding: .utf8
        )
        precondition(transcript == "전사문 원문")
    }

    private static func testSummaryConflictRequiresConsent() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = root.appendingPathComponent("Meeting-summary.md")
        try "기존 요약".write(to: existing, atomically: true, encoding: .utf8)
        let request = NoteFileExportRequest(
            source: NoteFileExportSource(
                transcript: "",
                audioURL: nil,
                summary: "새 요약"
            ),
            selectedItems: [.summary],
            textFormat: .markdown,
            baseName: "Meeting",
            destinationDirectory: root
        )
        precondition(NoteFileExporter.conflicts(for: request) == [existing])

        let blocked = NoteFileExporter.export(request, replaceExisting: false)

        precondition(blocked.savedItems.isEmpty)
        precondition(blocked.failures == [
            NoteFileExportFailure(item: .summary, reason: .destinationExists)
        ])
        let unchanged = try String(contentsOf: existing, encoding: .utf8)
        precondition(unchanged == "기존 요약")

        let replaced = NoteFileExporter.export(request, replaceExisting: true)

        precondition(replaced.savedItems == [.summary])
        precondition(replaced.isComplete)
        let updated = try String(contentsOf: existing, encoding: .utf8)
        precondition(updated == "새 요약")
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
        precondition(files == ["Meeting-summary.md"])
    }

    private static func testMissingSummaryKeepsSuccessfulTranscript() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let request = NoteFileExportRequest(
            source: NoteFileExportSource(transcript: "전사문 원문", audioURL: nil),
            selectedItems: [.transcript, .summary],
            textFormat: .plainText,
            baseName: "Meeting",
            destinationDirectory: root
        )

        let result = NoteFileExporter.export(request, replaceExisting: false)

        precondition(result.savedItems == [.transcript])
        precondition(result.failures == [
            NoteFileExportFailure(item: .summary, reason: .sourceMissing)
        ])
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
        precondition(files == ["Meeting.txt"])
    }

    private static func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("note-file-export-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
