import Foundation

@main
struct SettingsLocalizationTests {
    static func main() throws {
        try testTranscriptionLanguageKeepsCodeAndLocalizesDisplayName()
        try testTranscriptionModelKeepsIdentityAndLocalizesDescription()
        try testNativeWhisperModelKeepsIdentityAndLocalizesDescription()
        try testAudioImportDisplayKeepsModelIDAndLocalizesStaticLabels()
        try testSettingsSectionTitlePolicy()
        print("SettingsLocalizationTests passed")
    }

    private static func testTranscriptionLanguageKeepsCodeAndLocalizesDisplayName() throws {
        let korean = TranscriptionLanguage.find(code: "ko")
        let auto = TranscriptionLanguage.auto
        let localizationBundle = try compiledLocalizationBundle()

        assert(auto.code == "auto")
        assert(auto.localizedDisplayName(language: "en", bundle: localizationBundle) == "Auto Detect")
        assert(auto.localizedDisplayName(language: "ko", bundle: localizationBundle) == "자동 감지")
        assert(korean.code == "ko")
        assert(korean.localizedDisplayName(language: "en", bundle: localizationBundle) == "Korean")
        assert(korean.localizedDisplayName(language: "ko", bundle: localizationBundle) == "한국어")
        assert(korean.whisperArgument == "ko")
    }

    private static func testTranscriptionModelKeepsIdentityAndLocalizesDescription() throws {
        let appleSpeech = TranscriptionModel.find(id: "apple-speech")
        let localizationBundle = try compiledLocalizationBundle()

        assert(appleSpeech.id == "apple-speech")
        assert(appleSpeech.cacheDirectoryName == "models--apple-speech")
        assert(appleSpeech.localizedDescription(language: "en", bundle: localizationBundle) == "On-device · Fast")
        assert(appleSpeech.localizedDescription(language: "ko", bundle: localizationBundle) == "온디바이스 · 빠름")
    }

    private static func testNativeWhisperModelKeepsIdentityAndLocalizesDescription() throws {
        let model = NativeWhisperModelCatalog.recommended
        let localizationBundle = try compiledLocalizationBundle()

        assert(model.id == "whisper-large-v3-turbo")
        assert(model.expectedFileName == "ggml-large-v3-turbo.bin")
        assert(model.downloadURL.absoluteString == "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin")
        assert(model.localizedDescription(language: "en", bundle: localizationBundle) == "Fast local transcription with high accuracy. Recommended.")
        assert(model.localizedDescription(language: "ko", bundle: localizationBundle) == "빠르고 정확한 로컬 받아쓰기. 추천.")
    }

    private static func testAudioImportDisplayKeepsModelIDAndLocalizesStaticLabels() throws {
        let options = AudioImportOptions(
            fileExtension: "wav",
            currentChoice: .apiStandard(modelID: "whisper-large-v3"),
            apiStandardModelID: "whisper-large-v3"
        )
        let display = options.displayRows.first { $0.choice == .apiStandard(modelID: "whisper-large-v3") }!
        let localizationBundle = try compiledLocalizationBundle()

        assert(display.choice.id == "api-standard:whisper-large-v3")
        assert(display.localizedTitle(language: "en", bundle: localizationBundle) == "API Standard")
        assert(display.localizedTitle(language: "ko", bundle: localizationBundle) == "API 표준")
        assert(display.localizedCompactLabel(language: "ko", bundle: localizationBundle) == "표준 · whisper-large-v3")
    }

    private static func testSettingsSectionTitlePolicy() throws {
        let bundle = try compiledLocalizationBundle()

        for key in ["Note Browser", "Recording Overlay", "Google Calendar"] {
            assert(localizedCatalogString(key, language: "en", bundle: bundle) == key)
            assert(localizedCatalogString(key, language: "ko", bundle: bundle) == key)
        }

        let ordinaryKoreanTitles: [String: String] = [
            "App Appearance": "앱 외관",
            "Meeting Recording Reminders": "회의 녹음 알림",
            "Language": "언어",
            "System Prompt": "시스템 프롬프트",
            "Instruction Guard": "명령 보호",
            "Context Prompt": "컨텍스트 프롬프트",
            "Dictation Shortcuts": "받아쓰기 단축키",
            "Audio During Dictation": "받아쓰기 중 오디오",
            "Clipboard": "클립보드",
            "Voice Macros": "음성 매크로",
            "Sound Volume": "소리 크기",
            "Build": "빌드"
        ]
        for (key, expected) in ordinaryKoreanTitles {
            assert(localizedCatalogString(key, language: "ko", bundle: bundle) == expected)
        }
    }

    private static func compiledLocalizationBundle() throws -> Bundle {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let localizationRoot = root.appendingPathComponent("build/localization")
        guard let bundle = Bundle(path: localizationRoot.path) else {
            throw NSError(domain: "SettingsLocalizationTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing compiled localization bundle"])
        }
        return bundle
    }
}
