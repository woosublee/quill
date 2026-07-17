import Foundation

@main
struct LocalizationResourceTests {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        if CommandLine.arguments.count > 1 {
            guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--bundle" else {
                throw TestFailure("Usage: LocalizationResourceTests [--bundle <app-bundle>]")
            }
            try validateBundle(at: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true))
            print("LocalizationResourceTests bundle validation passed")
            return
        }

        let catalogURL = root.appendingPathComponent("Resources/Localization/Localizable.xcstrings")
        let catalogData = try Data(contentsOf: catalogURL)
        let catalog = try JSONSerialization.jsonObject(with: catalogData) as! [String: Any]

        assert(catalog["sourceLanguage"] as? String == "en")
        let strings = catalog["strings"] as! [String: Any]
        assert(!strings.isEmpty)

        for (key, rawEntry) in strings {
            let entry = rawEntry as? [String: Any] ?? [:]
            guard entry["shouldTranslate"] as? Bool != false else { continue }
            let localizations = entry["localizations"] as? [String: Any] ?? [:]
            for language in ["en", "ko"] {
                let localization = localizations[language] as? [String: Any]
                let unit = localization?["stringUnit"] as? [String: Any]
                let value = unit?["value"] as? String
                assert(value?.isEmpty == false, "Missing \(language) translation for \(key)")
            }
        }

        let continueKorean = try localizedValue(key: "Continue", language: "ko", root: root)
        let settingsKorean = try localizedValue(key: "Settings...", language: "ko", root: root)
        let startDictatingKorean = try localizedValue(key: "Start Dictating", language: "ko", root: root)
        assert(continueKorean == "계속")
        assert(settingsKorean == "설정...")
        assert(startDictatingKorean == "받아쓰기 시작")

        for language in ["en", "ko"] {
            let infoURL = root.appendingPathComponent("Resources/Localization/\(language).lproj/InfoPlist.strings")
            let info = try String(contentsOf: infoURL, encoding: .utf8)
            assert(info.contains("NSMicrophoneUsageDescription"))
            assert(info.contains("NSSpeechRecognitionUsageDescription"))
        }

        try assertTask3ExtractionCoverage(root: root, catalogStrings: strings)
        try assertTask3ReviewCoverage(root: root)
        try assertTask4SettingsExtractionCoverage(root: root, catalogStrings: strings)
        try assertTask5ApplicationMessageCoverage(root: root, catalogStrings: strings)
        try assertGoogleCalendarHealthMessageCoverage(root: root, catalogStrings: strings)
        try assertTask6OverlayCoverage(root: root, catalogStrings: strings)
        try assertLocalizedCancellationStatusReset(root: root)

        try assertFinalManagedSourceAudit(root: root, catalogStrings: strings)
        try assertIntentionalEnglishProductCopy(root: root, catalogStrings: strings)
        try assertRegularSettingsCardTitleCoverage(root: root, catalogStrings: strings)
        try assertCatalogPlaceholderCompatibility(catalogStrings: strings)
        try assertDeveloperDiagnosticsAreExcluded(catalogStrings: strings)
        try assertRepresentativeProductionKoreanTranslations(catalogStrings: strings)
        try assertInfoPlistTranslations(root: root)

        let settingsSource = try String(contentsOf: root.appendingPathComponent("Sources/SettingsView.swift"), encoding: .utf8)
        assert(settingsSource.contains("MicrophoneOptionRow(\n                    title: \"System Default\""))
        assert(settingsSource.contains("verbatimName: device.name,"))
        assert(settingsSource.contains("init(title: LocalizedStringKey"))
        assert(settingsSource.contains("init(verbatimName: String"))
        for key in ["Auto Detect", "System Default", "System Audio", "System Default + System Audio"] {
            let localizations = (strings[key] as? [String: Any])?["localizations"] as? [String: Any]
            for language in ["en", "ko"] {
                assert(!(((localizations?[language] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String ?? "").isEmpty, "Missing \(language) input localization for \(key)")
            }
        }
        for key in ["General", "Appearance", "Models", "Shortcuts", "Input", "About", "My calendars", "Shared calendars", "Primary", "My calendar", "Shared", "Use API Provider transcription to choose a final output language.", "Enable post-processing to choose a final output language.", "Final transcript language for post-processing."] {
            let localizations = (strings[key] as? [String: Any])?["localizations"] as? [String: Any]
            assert(!(((localizations?["en"] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String ?? "").isEmpty)
            assert(!(((localizations?["ko"] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String ?? "").isEmpty)
        }
        for key in ["Relaunching...", "%@ restores the audio state it changed when dictation ends.", "When enabled, %@ retries or falls back to the literal transcript if post-processing looks like it answered the dictated text instead of cleaning it.", "When on, your clipboard manager (Paste, Raycast, Maccy, etc.) records each dictation so you can find it in your recent history. When off, %@ marks dictations transient and your clipboard manager skips them."] {
            let localizations = (strings[key] as? [String: Any])?["localizations"] as? [String: Any]
            let en = (((localizations?["en"] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String)
            let ko = (((localizations?["ko"] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String)
            assert(en != ko, "Expected Korean regular Settings translation for \(key)")
        }
        for key in ["Transcription Model", "Used for speech-to-text transcription.", "Post-Processing Model", "Cleans up transcripts and applies formatting.", "Context Model", "Uses active-window context to improve transcription.", "Vision Model", "Analyzes screenshots for visual context.", "Same as spoken language", "English", "Portuguese"] {
            let localizations = (strings[key] as? [String: Any])?["localizations"] as? [String: Any]
            for language in ["en", "ko"] {
                assert(!(((localizations?[language] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String ?? "").isEmpty, "Missing required Task 4 \(language) key: \(key)")
            }
        }

        let noteBrowserSource = try String(
            contentsOf: root.appendingPathComponent("Sources/NoteBrowserView.swift"),
            encoding: .utf8
        )
        assert(noteBrowserSource.contains("help: LocalizedStringKey"))
        assert(noteBrowserSource.contains("let help: LocalizedStringKey"))
        assert(noteBrowserSource.contains("fieldLabel(_ key: LocalizedStringKey)"))
        assert(noteBrowserSource.contains("if vaultPath.isEmpty {\n                        Text(\"Select a folder\")"))
        assert(noteBrowserSource.contains("} else {\n                        Text(vaultPath)"))
        assert(strings["Obsidian Vault Folder"] != nil)

        let hangulPattern = try NSRegularExpression(pattern: "[가-힣]")
        let sourceFiles = ["Sources/NoteBrowserView.swift", "Sources/NoteListRowDisplayData.swift"]
        for sourceFile in sourceFiles {
            let source = try String(contentsOf: root.appendingPathComponent(sourceFile), encoding: .utf8)
            let lines = source.components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() {
                guard hangulPattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil else { continue }
                let previousLine = index > 0 ? lines[index - 1] : ""
                let isAllowlistedGeminiPrompt = previousLine.contains("localization-allowlist: exact non-UI Gemini model prompt")
                    && line.contains("@AppStorage(\"obsidian_gemini_prompt\")")
                assert(isAllowlistedGeminiPrompt, "Unexpected Hangul literal in \(sourceFile):\(index + 1)")
            }
        }

        print("LocalizationResourceTests passed")
    }

    private static func assertTask3ExtractionCoverage(root: URL, catalogStrings: [String: Any]) throws {
        let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let process = Process()
        process.currentDirectoryURL = root
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "xcstringstool", "extract", "--SwiftUI", "--modern-localizable-strings",
            "--output-format", "xcstrings", "-o", temporaryDirectory.path,
            "Sources/SetupView.swift", "Sources/MenuBarView.swift", "Sources/App.swift",
            "Sources/AppDelegate.swift", "Sources/SetupFlow.swift"
        ]
        try process.run()
        process.waitUntilExit()
        assert(process.terminationStatus == 0, "Task 3 localization extraction failed")

        let extractedURL = temporaryDirectory.appendingPathComponent("Localizable.xcstrings")
        let extractedData = try Data(contentsOf: extractedURL)
        let extractedCatalog = try JSONSerialization.jsonObject(with: extractedData) as! [String: Any]
        let extractedStrings = extractedCatalog["strings"] as! [String: Any]
        let exclusions: Set<String> = ["Open Run Log"]
        for extractedKey in extractedStrings.keys where !exclusions.contains(extractedKey) {
            let key = catalogKey(forExtractedKey: extractedKey)
            let entry = catalogStrings[key] as? [String: Any]
            let localizations = entry?["localizations"] as? [String: Any]
            for language in ["en", "ko"] {
                let unit = (localizations?[language] as? [String: Any])?["stringUnit"] as? [String: Any]
                assert(!(unit?["value"] as? String ?? "").isEmpty, "Missing Task 3 \(language) translation for \(key)")
            }
        }
    }

    private static func assertTask3ReviewCoverage(root: URL) throws {
        let appDelegateSource = try String(
            contentsOf: root.appendingPathComponent("Sources/AppDelegate.swift"),
            encoding: .utf8
        )
        assert(appDelegateSource.contains("isSettingsMenuItemTitle($0.title, localizedSettingsTitle: String(localized: \"Settings...\"))"))

        let testSource = try String(
            contentsOf: root.appendingPathComponent("Tests/LocalizationResourceTests.swift"),
            encoding: .utf8
        )
        guard let argumentsStart = testSource.range(of: "process.arguments = ["),
              let argumentsEnd = testSource.range(of: "        ]", range: argumentsStart.upperBound..<testSource.endIndex) else {
            assertionFailure("Task 3 extraction arguments are missing")
            return
        }
        let arguments = String(testSource[argumentsStart.lowerBound..<argumentsEnd.lowerBound])
        assert(arguments.contains("Sources/AppDelegate.swift"))
        assert(arguments.contains("Sources/SetupFlow.swift"))
    }


    private static func assertTask4SettingsExtractionCoverage(root: URL, catalogStrings: [String: Any]) throws {
        let settingsURL = root.appendingPathComponent("Sources/SettingsView.swift")
        let source = try String(contentsOf: settingsURL, encoding: .utf8)
        let startMarker = "// localization-exclusion: developer-diagnostics-start"
        let endMarker = "// localization-exclusion: developer-diagnostics-end"
        assert(source.components(separatedBy: startMarker).count == 3, "Expected exactly two developer diagnostic start markers")
        assert(source.components(separatedBy: endMarker).count == 3, "Expected exactly two developer diagnostic end markers")

        var remaining = source
        var excluded = ""
        while let start = remaining.range(of: startMarker), let end = remaining.range(of: endMarker, range: start.upperBound..<remaining.endIndex) {
            excluded += String(remaining[start.lowerBound..<end.upperBound])
            remaining.removeSubrange(start.lowerBound..<end.upperBound)
        }
        assert(excluded.contains("struct DebugSettingsView"))
        assert(excluded.contains("struct RunLogView"))
        assert(excluded.contains("struct RunLogEntryView"))
        assert(excluded.contains("struct PipelineStepView"))
        assert(remaining.contains("struct AppearanceSettingsView"))
        assert(remaining.contains("struct ModelsSettingsView"))
        assert(remaining.contains("struct VoiceMacroEditorView"))
        assert(remaining.contains("struct ModelRowView"))

        let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("quill-localization-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let filteredSettingsURL = temporaryDirectory.appendingPathComponent("SettingsView.swift")
        try remaining.write(to: filteredSettingsURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.currentDirectoryURL = root
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["xcstringstool", "extract", "--SwiftUI", "--modern-localizable-strings", "--output-format", "xcstrings", "-o", temporaryDirectory.path, filteredSettingsURL.path, "Sources/ModelDropdownView.swift"]
        try process.run()
        process.waitUntilExit()
        assert(process.terminationStatus == 0, "Task 4 localization extraction failed")

        let extractedData = try Data(contentsOf: temporaryDirectory.appendingPathComponent("Localizable.xcstrings"))
        let extracted = try JSONSerialization.jsonObject(with: extractedData) as! [String: Any]
        for extractedKey in (extracted["strings"] as! [String: Any]).keys where !extractedKey.isEmpty {
            let key = catalogKey(forExtractedKey: extractedKey)
            let entry = catalogStrings[key] as? [String: Any]
            let localizations = entry?["localizations"] as? [String: Any]
            for language in ["en", "ko"] {
                let unit = (localizations?[language] as? [String: Any])?["stringUnit"] as? [String: Any]
                assert(!(unit?["value"] as? String ?? "").isEmpty, "Missing Task 4 \(language) translation for \(key)")
            }
        }
    }

    private static func assertTask5ApplicationMessageCoverage(root: URL, catalogStrings: [String: Any]) throws {
        let appState = try String(contentsOf: root.appendingPathComponent("Sources/AppState.swift"), encoding: .utf8)
        let helper = try String(contentsOf: root.appendingPathComponent("Sources/LocalizedUserMessage.swift"), encoding: .utf8)
        let requiredPrefixes = [
            "Unable to clear run history", "Unable to delete run history entry", "Failed to save note title",
            "Failed to save transcript edit", "Unable to save imported audio note", "Unable to prepare retry",
            "Failed to save retry result", "Unable to save recovery entry", "Unable to save run history entry"
        ]
        for key in requiredPrefixes {
            assert(appState.contains("localizedCatalogString(\"\(key)\")"), "Missing Task 5 localized error prefix: \(key)")
            assertCatalogTranslations(for: key, catalogStrings: catalogStrings)
        }
        let guidance = "Unable to save the audio file. Check disk space or file permissions and try again."
        assert(appState.contains("localizedCatalogString(\"\(guidance)\")"))
        assertCatalogTranslations(for: guidance, catalogStrings: catalogStrings)
        let screenPermissionDetail = "Screen Recording access was not granted."
        let screenPermissionKey = "%@\n\nQuill requires Screen Recording permission to capture screenshots for context-aware transcription.\n\nGo to System Settings > Privacy & Security > Screen Recording and enable Quill."
        let screenshotFailureKey = "Failed to capture screenshot: %@\n\nA screenshot is required for context-aware transcription. Recording has been stopped."
        assertCatalogTranslations(for: screenPermissionDetail, catalogStrings: catalogStrings)
        assertCatalogTranslations(for: screenPermissionKey, catalogStrings: catalogStrings)
        assertCatalogTranslations(for: screenshotFailureKey, catalogStrings: catalogStrings)
        assert(helper.contains("static func screenRecordingPermission(detail: String, language: String, bundle: Bundle)"))
        assert(helper.contains("static func screenshotFailure(detail: String, language: String, bundle: Bundle)"))
        assert(appState.contains("showScreenshotPermissionAlert(message: localizedCatalogString(\"Screen Recording access was not granted.\"))"))
        assert(appState.contains("alert.informativeText = LocalizedUserMessage.screenRecordingPermission(detail: message)"))
        assert(appState.contains("alert.informativeText = LocalizedUserMessage.screenshotFailure(detail: message)"))
        assert(!appState.contains("LocalizedUserMessage.screenRecordingPermission(detail: message) +"))
        assert(!appState.contains("LocalizedUserMessage.screenshotFailure(detail: message) +"))
    }

    private static func assertGoogleCalendarHealthMessageCoverage(
        root: URL,
        catalogStrings: [String: Any]
    ) throws {
        let appState = try managedSource("Sources/AppState.swift", root: root)
        let settings = try managedSource("Sources/SettingsView.swift", root: root)
        let fixedKeys = [
            "Google Calendar needs reconnecting.",
            "Google Calendar needs reconnecting. Reconnect to restore meeting reminders and calendar-based note titles.",
            "Google Calendar needs reconnecting. Reconnect to restore meeting reminders.",
            "Google Calendar needs reconnecting. Calendar-based note titles may be unavailable.",
            "Some Google calendars could not be refreshed. Reminders may be incomplete.",
            "Some Google calendars could not be refreshed. Calendar-based note titles may be incomplete.",
            "Quill can’t access Google Calendar. Reconnect to restore meeting reminders and calendar-based note titles.",
            "Quill couldn’t refresh Google Calendar just now. Recording still works; reminders or note titles may be incomplete.",
            "Reconnect Google Calendar to keep meeting recording reminders working.",
            "Calendar reminders may be incomplete until the next successful refresh."
        ]
        let formattedKeys = [
            "Unable to refresh Google Calendar reminders: %@",
            "Unable to refresh Google Calendar: %@",
            "Unable to refresh Google Calendar for note titles: %@"
        ]

        for key in fixedKeys + formattedKeys {
            assertCatalogTranslations(for: key, catalogStrings: catalogStrings, requiresTranslation: true)
        }
        for key in fixedKeys where appState.contains(key) {
            assert(appState.contains("localizedCatalogString(\"\(key)\")"), "Calendar message bypasses the catalog: \(key)")
        }
        for key in fixedKeys where settings.contains(key) {
            assert(settings.contains("localizedCatalogString(\"\(key)\")"), "Settings fallback bypasses the catalog: \(key)")
        }
        for key in formattedKeys {
            assert(appState.contains("localizedCatalogFormat(\"\(key)\", error.localizedDescription)"), "Calendar detail must stay a verbatim format argument: \(key)")
        }
    }

    private static func assertTask6OverlayCoverage(root: URL, catalogStrings: [String: Any]) throws {
        let recordingOverlay = try String(contentsOf: root.appendingPathComponent("Sources/RecordingOverlay.swift"), encoding: .utf8)
        let meetingOverlay = try String(contentsOf: root.appendingPathComponent("Sources/MeetingReminderOverlay.swift"), encoding: .utf8)
        let helper = try String(contentsOf: root.appendingPathComponent("Sources/OverlayDisplayCopy.swift"), encoding: .utf8)

        assert(helper.contains("static func meetingStarts("))
        assert(helper.contains("static func inputChanged("))
        assert(helper.contains("static func updateAvailable("))
        assert(meetingOverlay.contains("OverlayDisplayCopy.meetingStarts(at: startTimeText(for: start))"))
        assert(meetingOverlay.contains("Text(displayData.title)"))
        assert(recordingOverlay.contains("UpdateAvailableOverlayView(version: state.updateVersion"))
        assert(recordingOverlay.contains("Text(verbatim: OverlayDisplayCopy.updateAvailable(version: version))"))
        assert(recordingOverlay.contains("var helpText: LocalizedStringKey"))
        assert(recordingOverlay.contains("var displayName: LocalizedStringKey"))
        assert(recordingOverlay.contains("isStaticQuillName"))

        for key in [
            "Centered", "Notch Sides",
            "Show the recording overlay centered below the notch.",
            "Show recording status beside the notch when supported. Update alerts stay centered.",
            "Elapsed time · click to switch audio input",
            "Hover for elapsed time · click to switch audio input",
            "Switch audio input",
            "Starts at %@", "Input changed to %@", "Update available", "Update available: %@",
            "Start", "Close"
        ] {
            assertCatalogTranslations(for: key, catalogStrings: catalogStrings)
        }
    }

    private static func assertLocalizedCancellationStatusReset(root: URL) throws {
        let appState = try String(contentsOf: root.appendingPathComponent("Sources/AppState.swift"), encoding: .utf8)
        assert(appState.components(separatedBy: "let cancelledStatus = localizedCatalogString(\"Cancelled\")").count == 3)
        assert(appState.components(separatedBy: "statusText = cancelledStatus").count == 3)
        assert(appState.components(separatedBy: "statusText == cancelledStatus").count == 3)
        assert(appState.components(separatedBy: "matching: [cancelledStatus]").count == 3)
        assert(!appState.contains("statusText == \"Cancelled\""))
        assert(!appState.contains("matching: [\"Cancelled\"]"))
    }


    private struct TestFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private static func validateBundle(at appURL: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: appURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw TestFailure("App bundle does not exist: \(appURL.path)")
        }

        let resourcesURL = appURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        let requiredInfoKeys = ["NSMicrophoneUsageDescription", "NSSpeechRecognitionUsageDescription"]
        var languageBundles: [String: Bundle] = [:]
        for language in ["en", "ko"] {
            let localizationURL = resourcesURL.appendingPathComponent("\(language).lproj", isDirectory: true)
            for fileName in ["Localizable.strings", "InfoPlist.strings"] {
                let fileURL = localizationURL.appendingPathComponent(fileName)
                guard FileManager.default.fileExists(atPath: fileURL.path) else {
                    throw TestFailure("Missing bundled localization resource: \(fileURL.path)")
                }
            }
            guard let bundle = Bundle(url: localizationURL) else {
                throw TestFailure("Unable to load language bundle: \(localizationURL.path)")
            }
            languageBundles[language] = bundle

            let infoValues = NSDictionary(contentsOf: localizationURL.appendingPathComponent("InfoPlist.strings")) as? [String: String] ?? [:]
            guard Set(infoValues.keys) == Set(requiredInfoKeys) else {
                throw TestFailure("Unexpected bundled InfoPlist.strings keys for \(language)")
            }
            for key in requiredInfoKeys where infoValues[key]?.isEmpty != false {
                throw TestFailure("Missing bundled \(language) InfoPlist value for \(key)")
            }
        }

        let representativeStatic: [String: [String: String]] = [
            "en": ["Continue": "Continue", "Settings...": "Settings...", "Start Dictating": "Start Dictating"],
            "ko": ["Continue": "계속", "Settings...": "설정...", "Start Dictating": "받아쓰기 시작"]
        ]
        for language in ["en", "ko"] {
            guard let bundle = languageBundles[language] else { continue }
            for (key, expected) in representativeStatic[language] ?? [:] {
                let value = bundle.localizedString(forKey: key, value: nil, table: "Localizable")
                guard value == expected else {
                    throw TestFailure("Unexpected bundled \(language) value for \(key): \(value)")
                }
            }
        }

        try assertBundledDynamicString(
            key: "Input changed to %@",
            arguments: ["Studio Display"],
            expected: ["en": "Input changed to Studio Display", "ko": "입력이 Studio Display(으)로 변경됨"],
            languageBundles: languageBundles
        )
        try assertBundledDynamicString(
            key: "Meeting starts in %d minutes",
            arguments: [3],
            expected: ["en": "Meeting starts in 3 minutes", "ko": "회의가 3분 후 시작됩니다"],
            languageBundles: languageBundles
        )
        try assertBundledDynamicString(
            key: "Welcome to %@",
            arguments: ["Quill"],
            expected: ["en": "Welcome to Quill", "ko": "Quill에 오신 것을 환영합니다."],
            languageBundles: languageBundles
        )


        let placeholderPattern = try NSRegularExpression(pattern: #"%(?:@|d|lld|arg)"#)
        for key in ["Input changed to %@", "Meeting starts in %d minutes", "Welcome to %@"] {
            let expectedPlaceholders = placeholders(in: key, pattern: placeholderPattern)
            for language in ["en", "ko"] {
                guard let bundle = languageBundles[language] else { continue }
                let localized = bundle.localizedString(forKey: key, value: nil, table: "Localizable")
                guard placeholders(in: localized, pattern: placeholderPattern) == expectedPlaceholders else {
                    throw TestFailure("Bundled \(language) placeholder mismatch for \(key)")
                }
            }
        }
    }

    private static func assertBundledDynamicString(
        key: String,
        arguments: [CVarArg],
        expected: [String: String],
        languageBundles: [String: Bundle]
    ) throws {
        for language in ["en", "ko"] {
            guard let bundle = languageBundles[language], let expectedValue = expected[language] else { continue }
            let localized = bundle.localizedString(forKey: key, value: nil, table: "Localizable")
            let value = String(format: localized, locale: Locale(identifier: language), arguments: arguments)
            guard value == expectedValue else {
                throw TestFailure("Unexpected bundled \(language) dynamic value for \(key): \(value)")
            }
        }
    }

    private static func assertFinalManagedSourceAudit(root: URL, catalogStrings: [String: Any]) throws {
        let managedSourceFiles = [
            "Sources/NoteBrowserView.swift", "Sources/NoteListRowDisplayData.swift",
            "Sources/SetupView.swift", "Sources/MenuBarView.swift", "Sources/ShortcutComponents.swift",
            "Sources/App.swift",
            "Sources/AppDelegate.swift", "Sources/SetupFlow.swift", "Sources/SettingsView.swift",
            "Sources/ModelDropdownView.swift", "Sources/AppState.swift", "Sources/AudioImportOptions.swift",
            "Sources/CalendarRecordingReminderScheduler.swift", "Sources/LocalizedUserMessage.swift",
            "Sources/UpdateManager.swift", "Sources/NativeWhisperModel.swift",
            "Sources/TranscriptionLanguage.swift", "Sources/TranscriptionModel.swift",
            "Sources/RecordingOverlay.swift", "Sources/MeetingReminderOverlay.swift",
            "Sources/OverlayDisplayCopy.swift"
        ]
        for sourceFile in managedSourceFiles {
            assert(FileManager.default.fileExists(atPath: root.appendingPathComponent(sourceFile).path), "Missing managed source file: \(sourceFile)")
        }

        let extractedKeys = try extractManagedKeys(root: root, sourceFiles: managedSourceFiles)
        let exactNonCatalogSwiftUIKeys: Set<String> = [
            "Open Run Log", "·", "API", "Legacy mlx-whisper", "REC",
            "%arg.md saved", "Saved file name: %arg.md"
        ]
        for extractedKey in extractedKeys where !extractedKey.isEmpty && !exactNonCatalogSwiftUIKeys.contains(extractedKey) {
            assertCatalogTranslations(
                for: catalogKey(forExtractedKey: extractedKey),
                catalogStrings: catalogStrings,
                requiresTranslation: true
            )
        }

        let customLookupPattern = try NSRegularExpression(pattern: #"localizedCatalogString\(\s*\"((?:\\.|[^\"\\])*)\""#)
        for sourceFile in managedSourceFiles {
            let source = try managedSource(sourceFile, root: root)
            let range = NSRange(source.startIndex..., in: source)
            for match in customLookupPattern.matches(in: source, range: range) {
                guard let keyRange = Range(match.range(at: 1), in: source) else { continue }
                let key = String(source[keyRange])
                    .replacingOccurrences(of: #"\n"#, with: "\n")
                    .replacingOccurrences(of: #"\""#, with: #"""#)
                    .replacingOccurrences(of: #"\\"#, with: #"\"#)
                assertCatalogTranslations(for: key, catalogStrings: catalogStrings)
            }
        }

        let hangulPattern = try NSRegularExpression(pattern: "[가-힣]")
        let exactHangulExceptions: Set<String> = [
            #"@AppStorage("obsidian_gemini_prompt") private var geminiPrompt: String = "다음은 음성 전사 내용입니다. 핵심 내용을 유지하면서 읽기 쉽게 정리해주세요. 마크다운 형식으로 작성하되, 불필요한 설명 없이 정리된 내용만 출력해주세요.\n옵시디언에 다른 회의록을 참고하여 컨텍스트와 작성 포맷을 통일하여 주세요.""#,
            #"TranscriptionLanguage(code: "ko", displayName: "한국어"),"#,
            #"description: "시스템 내장 · 온디바이스 · 빠름""#,
            #"description: "빠름 · 정확도 높음 (추천)""#,
            #"description: "최고 정확도 · 느림""#,
            #"description: "중간 속도 · 중간 정확도""#,
            #"description: "빠름 · 정확도 낮음""#
        ]
        for sourceFile in managedSourceFiles {
            let source = try managedSource(sourceFile, root: root)
            for (index, line) in source.components(separatedBy: .newlines).enumerated() {
                guard hangulPattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil else { continue }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let isComment = trimmed.hasPrefix("//") || trimmed.hasPrefix("///")
                let containsOnlyCommentHangul = line.split(separator: "//", maxSplits: 1).first.map {
                    hangulPattern.firstMatch(in: String($0), range: NSRange($0.startIndex..., in: $0)) == nil
                } ?? false
                assert(isComment || containsOnlyCommentHangul || exactHangulExceptions.contains(trimmed), "Unexpected Hangul literal in \(sourceFile):\(index + 1): \(trimmed)")
            }
        }
    }

    private static func assertIntentionalEnglishProductCopy(
        root: URL,
        catalogStrings: [String: Any]
    ) throws {
        let noteBrowser = try managedSource("Sources/NoteBrowserView.swift", root: root)
        assert(noteBrowser.contains("Text(verbatim: \"Recordings\")"))
        assert(noteBrowser.contains("Text(verbatim: \"Transcription\")"))
        assert(!noteBrowser.contains("Text(\"Recordings\")"))
        assert(!noteBrowser.contains("Text(\"Transcription\")"))

        for key in ["Note Browser", "Recording Overlay", "Google Calendar"] {
            let entry = catalogStrings[key] as? [String: Any]
            assert(entry?["shouldTranslate"] as? Bool == false, "Feature name must be an explicit English exception: \(key)")
            let localizations = entry?["localizations"] as? [String: Any]
            for language in ["en", "ko"] {
                let value = (((localizations?[language] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String)
                assert(value == key, "Feature name must stay English for \(language): \(key)")
            }
        }
    }

    private static func assertRegularSettingsCardTitleCoverage(
        root: URL,
        catalogStrings: [String: Any]
    ) throws {
        let settings = try managedSource("Sources/SettingsView.swift", root: root)
        let pattern = try NSRegularExpression(pattern: #"SettingsCard\(\"((?:\\.|[^\"\\])*)\""#)
        let range = NSRange(settings.startIndex..., in: settings)
        let englishFeatureNames: Set<String> = ["Note Browser", "Recording Overlay", "Google Calendar"]

        for match in pattern.matches(in: settings, range: range) {
            guard let titleRange = Range(match.range(at: 1), in: settings) else { continue }
            let key = String(settings[titleRange])
            assertCatalogTranslations(
                for: key,
                catalogStrings: catalogStrings,
                requiresTranslation: !englishFeatureNames.contains(key)
            )
        }
    }

    private static func extractManagedKeys(root: URL, sourceFiles: [String]) throws -> Set<String> {
        let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("quill-localization-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

        var extractionFiles: [String] = []
        for sourceFile in sourceFiles {
            var source = try managedSource(sourceFile, root: root)
            if sourceFile == "Sources/RecordingOverlay.swift" {
                source = source.replacingOccurrences(
                    of: "isStaticQuillName ? String(localized: String.LocalizationValue(name)) : name",
                    with: "isStaticQuillName ? localizedCatalogString(name) : name"
                )
            }
            let outputURL = temporaryDirectory.appendingPathComponent(URL(fileURLWithPath: sourceFile).lastPathComponent)
            try source.write(to: outputURL, atomically: true, encoding: .utf8)
            extractionFiles.append(outputURL.path)
        }

        let process = Process()
        process.currentDirectoryURL = root
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "xcstringstool", "extract", "--SwiftUI", "--modern-localizable-strings",
            "--output-format", "xcstrings", "-o", temporaryDirectory.path
        ] + extractionFiles
        try process.run()
        process.waitUntilExit()
        assert(process.terminationStatus == 0, "Final managed localization extraction failed")

        let extractedData = try Data(contentsOf: temporaryDirectory.appendingPathComponent("Localizable.xcstrings"))
        let extracted = try JSONSerialization.jsonObject(with: extractedData) as! [String: Any]
        return Set((extracted["strings"] as? [String: Any] ?? [:]).keys)
    }

    private static func managedSource(_ sourceFile: String, root: URL) throws -> String {
        var source = try String(contentsOf: root.appendingPathComponent(sourceFile), encoding: .utf8)
        guard sourceFile == "Sources/SettingsView.swift" else { return source }

        let startMarker = "// localization-exclusion: developer-diagnostics-start"
        let endMarker = "// localization-exclusion: developer-diagnostics-end"
        while let start = source.range(of: startMarker),
              let end = source.range(of: endMarker, range: start.upperBound..<source.endIndex) {
            source.removeSubrange(start.lowerBound..<end.upperBound)
        }
        return source
    }

    private static func catalogKey(forExtractedKey key: String) -> String {
        key.replacingOccurrences(of: "%arg", with: "%@")
    }

    private static func assertCatalogPlaceholderCompatibility(catalogStrings: [String: Any]) throws {
        let placeholderPattern = try NSRegularExpression(pattern: #"%(?:@|d|lld|arg)"#)
        for (key, rawEntry) in catalogStrings {
            let entry = rawEntry as? [String: Any] ?? [:]
            guard entry["shouldTranslate"] as? Bool != false else { continue }
            let localizations = entry["localizations"] as? [String: Any] ?? [:]
            let en = (((localizations["en"] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String) ?? ""
            let ko = (((localizations["ko"] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String) ?? ""
            let keyPlaceholders = placeholders(in: key, pattern: placeholderPattern)
            assert(placeholders(in: en, pattern: placeholderPattern) == keyPlaceholders, "English placeholder mismatch for \(key)")
            assert(placeholders(in: ko, pattern: placeholderPattern) == keyPlaceholders, "Korean placeholder mismatch for \(key)")
        }
    }

    private static func placeholders(in value: String, pattern: NSRegularExpression) -> [String] {
        pattern.matches(in: value, range: NSRange(value.startIndex..., in: value)).compactMap {
            Range($0.range, in: value).map { String(value[$0]) }
        }
    }

    private static func assertDeveloperDiagnosticsAreExcluded(catalogStrings: [String: Any]) throws {
        let diagnosticOnlyKeys = [
            "Debug", "Display the update available overlay after dictation finishes.",
            "No Context", "No LLM", "No context captured",
            "No runs yet. Use dictation to populate history.", "Pipeline", "Run Log",
            "Show Meeting Reminder", "Show Update Overlay Now",
            "Show a sample calendar reminder overlay. Turn on Debug Overlay first to preview the recording (wrapping) variant.",
            "Show after dictation", "Show the recording overlay with simulated audio levels.",
            "Stored locally. Only the %@ most recent runs are kept."
        ]
        for key in diagnosticOnlyKeys {
            let entry = catalogStrings[key] as? [String: Any]
            assert(entry == nil || entry?["shouldTranslate"] as? Bool == false, "Developer diagnostic key must not require translations: \(key)")
        }
    }

    private static func assertRepresentativeProductionKoreanTranslations(catalogStrings: [String: Any]) throws {
        for key in [
            "No audio recorded",
            "When enabled, %@ retries or falls back to the literal transcript if post-processing looks like it answered the dictated text instead of cleaning it.",
            "When on, your clipboard manager (Paste, Raycast, Maccy, etc.) records each dictation so you can find it in your recent history. When off, %@ marks dictations transient and your clipboard manager skips them."
        ] {
            guard let entry = catalogStrings[key] as? [String: Any], entry["shouldTranslate"] as? Bool != false else { continue }
            let localizations = entry["localizations"] as? [String: Any]
            let en = (((localizations?["en"] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String)
            let ko = (((localizations?["ko"] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String)
            assert(en != ko, "Expected Korean production translation for \(key)")
        }
    }

    private static func assertInfoPlistTranslations(root: URL) throws {
        let requiredKeys = ["NSMicrophoneUsageDescription", "NSSpeechRecognitionUsageDescription"]
        var valuesByLanguage: [String: [String: String]] = [:]
        for language in ["en", "ko"] {
            let url = root.appendingPathComponent("Resources/Localization/\(language).lproj/InfoPlist.strings")
            let values = NSDictionary(contentsOf: url) as? [String: String] ?? [:]
            valuesByLanguage[language] = values
            assert(Set(values.keys) == Set(requiredKeys), "Unexpected InfoPlist.strings keys for \(language)")
            for key in requiredKeys {
                assert(values[key]?.isEmpty == false, "Missing \(language) InfoPlist translation for \(key)")
            }
        }
        for key in requiredKeys {
            assert(valuesByLanguage["en"]?[key] != valuesByLanguage["ko"]?[key], "Expected distinct Korean InfoPlist translation for \(key)")
        }
    }

    private static func assertCatalogTranslations(
        for key: String,
        catalogStrings: [String: Any],
        requiresTranslation: Bool = false
    ) {
        let entry = catalogStrings[key] as? [String: Any]
        if requiresTranslation {
            assert(entry?["shouldTranslate"] as? Bool != false, "Managed production key is marked non-translatable: \(key)")
        }
        let localizations = entry?["localizations"] as? [String: Any]
        for language in ["en", "ko"] {
            let value = (((localizations?[language] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String)
            assert(!(value ?? "").isEmpty, "Missing Task 5 \(language) translation for \(key)")
        }
    }

    private static func localizedValue(
        key: String,
        language: String,
        root: URL
    ) throws -> String {
        let url = root
            .appendingPathComponent("build/localization")
            .appendingPathComponent("\(language).lproj/Localizable.strings")
        let dictionary = NSDictionary(contentsOf: url) as? [String: String] ?? [:]
        return dictionary[key] ?? key
    }
}
