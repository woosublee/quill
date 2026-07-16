import Foundation

@main
struct LocalizationResourceTests {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
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
        try assertTask6OverlayCoverage(root: root, catalogStrings: strings)
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
        for key in ["Relaunching...", "%arg restores the audio state it changed when dictation ends.", "When enabled, %arg retries or falls back to the literal transcript if post-processing looks like it answered the dictated text instead of cleaning it.", "When on, your clipboard manager (Paste, Raycast, Maccy, etc.) records each dictation so you can find it in your recent history. When off, %arg marks dictations transient and your clipboard manager skips them."] {
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
        for key in extractedStrings.keys where !exclusions.contains(key) {
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

        let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
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
        for key in (extracted["strings"] as! [String: Any]).keys where !key.isEmpty {
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
            "Starts at %@", "Input changed to %@", "Update available: %@",
            "Start", "Close"
        ] {
            assertCatalogTranslations(for: key, catalogStrings: catalogStrings)
        }
    }

    private static func assertCatalogTranslations(for key: String, catalogStrings: [String: Any]) {
        let localizations = (catalogStrings[key] as? [String: Any])?["localizations"] as? [String: Any]
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
