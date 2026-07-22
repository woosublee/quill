import Foundation

@main
struct SettingsLocalizationTests {
    static func main() throws {
        try testTranscriptionLanguageKeepsCodeAndLocalizesDisplayName()
        try testTranscriptionModelKeepsIdentityAndLocalizesDescription()
        try testNativeWhisperModelKeepsIdentityAndLocalizesDescription()
        try testAudioImportDisplayKeepsModelIDAndLocalizesStaticLabels()
        try testSettingsSectionTitlePolicy()
        try testGoogleCalendarHealthMessagesLocalizeWithoutChangingDetail()
        try testCalendarReminderLeadTimeUsesLocalizedCopy()
        try testRecordingOverlaySettingsCopyLocalizes()
        try testModelFirstSettingsCopyLocalizes()
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

    private static func testGoogleCalendarHealthMessagesLocalizeWithoutChangingDetail() throws {
        let bundle = try compiledLocalizationBundle()
        let detail = "HTTP 503: upstream unavailable"

        assert(
            localizedCatalogString(
                "Google Calendar needs reconnecting. Reconnect to restore meeting reminders and calendar-based note titles.",
                language: "ko",
                bundle: bundle
            ) == "Google Calendar를 다시 연결해야 합니다. 회의 알림과 캘린더 기반 노트 제목을 복원하려면 다시 연결하세요."
        )
        assert(
            localizedCatalogFormat(
                "Unable to refresh Google Calendar: %@",
                detail,
                language: "ko",
                bundle: bundle
            ) == "Google Calendar를 새로 고치지 못했습니다: \(detail)"
        )
    }

    private static func testCalendarReminderLeadTimeUsesLocalizedCopy() throws {
        let settingsSource = try String(contentsOfFile: "Sources/SettingsView.swift", encoding: .utf8)

        assert(
            settingsSource.contains(
                "CalendarRecordingReminderScheduler.leadTimeOptionTitle(minutes)"
            )
        )
        assert(!settingsSource.contains("\"\\(minutes) min before\""))
    }

    private static func testRecordingOverlaySettingsCopyLocalizes() throws {
        let bundle = try compiledLocalizationBundle()
        let expected: [String: String] = [
            "Notch-side menu-bar overlay": "노치 양옆 메뉴 막대 오버레이",
            "Centered drop-down pill": "중앙 드롭다운 필",
            "Waveform display": "파형 표시",
            "Waveform only": "파형만 표시",
            "Show elapsed time on hover": "포인터를 올리면 경과 시간 표시",
            "Show elapsed time instead of waveform": "파형 대신 경과 시간 표시",
            "Selected": "선택됨",
            "Not selected": "선택되지 않음"
        ]
        for (key, value) in expected {
            assert(localizedCatalogString(key, language: "ko", bundle: bundle) == value)
        }
    }

    private static func testModelFirstSettingsCopyLocalizes() throws {
        let bundle = try compiledLocalizationBundle()
        let expected: [String: String] = [
            "Cloud Provider": "클라우드 공급자",
            "Cloud models use this shared OpenAI-compatible provider.": "클라우드 모델은 이 공통 OpenAI-compatible 공급자를 사용합니다.",
            "API Key configured": "API Key가 설정됨",
            "Convert speech to text.": "음성을 텍스트로 변환합니다.",
            "Cloud transcription requires an API key. Add one in Cloud Provider or use the transcription override in Details.": "클라우드 전사를 사용하려면 API Key가 필요합니다. 클라우드 공급자에서 추가하거나 세부 설정의 전사 전용 설정을 사용하세요.",
            "Details": "세부 설정",
            "Model": "모델",
            "Custom Standard API Model": "사용자 지정 표준 API 모델",
            "e.g. custom-transcription-model": "예: custom-transcription-model",
            "Add a custom model ID when it is not listed in the main Model menu.": "기본 모델 메뉴에 없는 사용자 지정 모델 ID를 추가합니다.",
            "Show Realtime transcription option": "실시간 전사 옵션 표시",
            "Download required": "다운로드 필요",
            "Downloading...": "다운로드 중...",
            "Local Whisper Download in Progress": "Local Whisper 다운로드 진행 중",
            "Closing Settings will cancel the model download and remove the partial file.": "Settings를 닫으면 모델 다운로드가 취소되고 완료되지 않은 파일이 제거됩니다.",
            "Keep Settings Open": "Settings 열어 두기",
            "Close and Cancel Download": "닫고 다운로드 취소",
            "Post-processing": "후처리",
            "Clean up wording, formatting, and language.": "문장 표현, 형식, 언어를 정리합니다.",
            "Add an API key in Cloud Provider to enable Post-processing.": "후처리를 활성화하려면 클라우드 공급자에서 API Key를 추가하세요.",
            "Post-processing is on, but cloud processing is unavailable until an API key is configured.": "후처리가 켜져 있지만 API Key를 설정하기 전에는 클라우드 처리를 사용할 수 없습니다.",
            "Normal dictation uses the raw transcript while Post-processing is off. Edit Mode still uses this model configuration.": "후처리가 꺼져 있으면 일반 받아쓰기는 원본 전사문을 사용합니다. Edit Mode는 계속 이 모델 설정을 사용합니다.",
            "Context": "컨텍스트",
            "Use the current app and screen to improve context.": "현재 앱과 화면을 사용해 맥락을 보완합니다.",
            "Add an API key in Cloud Provider to enable Context.": "컨텍스트를 활성화하려면 클라우드 공급자에서 API Key를 추가하세요.",
            "Context is on, but AI context analysis is unavailable until an API key is configured.": "컨텍스트가 켜져 있지만 API Key를 설정하기 전에는 AI 컨텍스트 분석을 사용할 수 없습니다.",
            "Context capture is off. Quill skips app context and screenshots for normal dictation.": "컨텍스트 캡처가 꺼져 있습니다. Quill은 일반 받아쓰기에서 앱 맥락과 스크린샷을 건너뜁니다.",
            "Paste Automatically": "자동으로 붙여넣기",
            "When off, Quill copies the transcript to the clipboard so you can paste it manually.": "끄면 Quill이 전사문을 클립보드에 복사하며, 필요할 때 직접 붙여넣을 수 있습니다.",
            "Used for transcript cleanup and Edit Mode transforms.": "전사문 정리와 Edit Mode 변환에 사용합니다.",
            "Used for context inference, with a text-only retry when screenshot analysis fails.": "컨텍스트 추론에 사용하며, 스크린샷 분석에 실패하면 텍스트 전용으로 다시 시도합니다.",
            "Post-Processing Fallback Model": "후처리 대체 모델",
            "Used as the explicit retry model for transcript cleanup and Edit Mode transforms.": "전사문 정리와 Edit Mode 변환을 다시 시도할 때 사용할 모델입니다.",
            "Edit Mode uses this model, fallback model, Output Language, and Custom Vocabulary. Invocation Style and Extra Modifier remain in Shortcuts.": "Edit Mode는 이 모델, 대체 모델, 출력 언어 및 사용자 지정 어휘를 사용합니다. 실행 방식과 추가 보조 키는 단축키에 그대로 있습니다.",
            "Output Language remains available for Edit Mode transforms.": "출력 언어는 Edit Mode 변환에서도 계속 사용할 수 있습니다.",
            "Output Language is unavailable while Post-processing and Edit Mode are off.": "후처리와 Edit Mode가 모두 꺼져 있으면 출력 언어를 사용할 수 없습니다.",
            "Final transcript language for post-processing and Edit Mode transforms.": "후처리와 Edit Mode 변환에 사용할 최종 전사문 언어입니다.",
            "Spoken language hint for speech recognition. Auto Detect works for most users.": "음성 인식을 위한 발화 언어 힌트입니다. 대부분의 사용자는 자동 감지를 사용하면 됩니다.",
            "Stream audio while recording (realtime)": "녹음 중 오디오 스트리밍(실시간)",
            "Streams audio through the provider's OpenAI-compatible /v1/realtime WebSocket so transcription runs while you speak.": "제공자의 OpenAI-compatible /v1/realtime WebSocket으로 오디오를 스트리밍하여 말하는 동안 전사를 실행합니다.",
            "Realtime Transcription Model": "실시간 전사 모델",
            "Used only for realtime streaming. Leave empty for providers that supply a server default.": "실시간 스트리밍에만 사용합니다. 서버 기본값을 제공하는 공급자에서는 비워 두세요."
        ]

        for (key, korean) in expected {
            assert(localizedCatalogString(key, language: "en", bundle: bundle) == key)
            assert(localizedCatalogString(key, language: "ko", bundle: bundle) == korean)
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
