import Foundation

@main
struct SettingsLocalizationTests {
    static func main() throws {
        try testTranscriptionLanguageKeepsCodeAndLocalizesDisplayName()
        try testTranscriptionModelKeepsIdentityAndLocalizesDescription()
        try testNativeWhisperModelKeepsIdentityAndLocalizesDescription()
        try testAudioImportDisplayKeepsModelIDAndLocalizesStaticLabels()
        try testSystemDefaultMicrophoneLabelLocalization()
        try testSettingsSectionTitlePolicy()
        try testGoogleCalendarHealthMessagesLocalizeWithoutChangingDetail()
        try testCalendarReminderLeadTimeUsesLocalizedCopy()
        try testRecordingOverlaySettingsCopyLocalizes()
        try testModelFirstSettingsCopyLocalizes()
        try testMeetingSummaryCopyLocalizes()
        try testModelDownloadTerminationCopyLocalizes()
        try testCombinedAudioSourceUnavailableReasonsLocalize()
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
        let legacyModel = TranscriptionModel.find(id: "mlx-community/whisper-medium-mlx")
        let options = AudioImportOptions(
            fileExtension: "wav",
            currentChoice: .apiStandard(modelID: "whisper-large-v3"),
            apiStandardModelID: "whisper-large-v3",
            legacyLocalWhisperModels: [legacyModel]
        )
        let display = options.displayRows.first { $0.choice == .apiStandard(modelID: "whisper-large-v3") }!
        let legacyDisplay = options.displayRows.first { $0.choice == .legacyMlxWhisper(model: legacyModel) }!
        let localizationBundle = try compiledLocalizationBundle()

        assert(display.choice.id == "api-standard:whisper-large-v3")
        assert(display.section == "Cloud")
        assert(display.localizedTitle(language: "en", bundle: localizationBundle) == "API Standard")
        assert(display.localizedTitle(language: "ko", bundle: localizationBundle) == "API 표준")
        assert(display.localizedCompactLabel(language: "ko", bundle: localizationBundle) == "표준 · whisper-large-v3")
        assert(display.localizedCurrentLabel(language: "en", bundle: localizationBundle) == "Cloud · Standard · whisper-large-v3")
        assert(display.localizedCurrentLabel(language: "ko", bundle: localizationBundle) == "클라우드 · 표준 · whisper-large-v3")

        assert(legacyDisplay.section == "On This Mac")
        assert(legacyDisplay.title == "Legacy mlx-whisper")
        assert(legacyDisplay.localizedCurrentLabel(language: "en", bundle: localizationBundle) == "On This Mac · Legacy · Whisper Medium")
        assert(legacyDisplay.localizedCurrentLabel(language: "ko", bundle: localizationBundle) == "이 Mac에서 · 레거시 · Whisper Medium")
    }

    private static func testSystemDefaultMicrophoneLabelLocalization() throws {
        let bundle = try compiledLocalizationBundle()

        assert(
            localizedCatalogFormat(
                "System Default (%@)",
                "MacBook Air Microphone",
                language: "en",
                bundle: bundle
            ) == "System Default (MacBook Air Microphone)"
        )
        assert(
            localizedCatalogFormat(
                "System Default (%@)",
                "MacBook Air Microphone",
                language: "ko",
                bundle: bundle
            ) == "시스템 기본값 (MacBook Air Microphone)"
        )
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
            "Custom API Model": "사용자 지정 API 모델",
            "e.g. provider/custom-model": "예: provider/custom-model",
            "Use Model": "모델 사용",
            "Enter an API model ID that is not listed above. Use the main Model menu to return to a listed model.": "위 목록에 없는 API 모델 ID를 입력합니다. 목록의 모델로 돌아가려면 위의 모델 메뉴에서 선택하세요.",
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
            "This model does not support screen Context.": "이 모델은 화면 컨텍스트를 지원하지 않습니다.",
            "Choose an image-capable model to enable Context.": "Context를 활성화하려면 이미지를 지원하는 모델을 선택하세요.",
            "Paste Automatically": "자동으로 붙여넣기",
            "When off, Quill copies the transcript to the clipboard so you can paste it manually.": "끄면 Quill이 전사문을 클립보드에 복사하며, 필요할 때 직접 붙여넣을 수 있습니다.",
            "Used for transcript cleanup and Edit Mode transforms.": "전사문 정리와 Edit Mode 변환에 사용합니다.",
            "Used for context inference, with a text-only retry when screenshot analysis fails.": "컨텍스트 추론에 사용하며, 스크린샷 분석에 실패하면 텍스트 전용으로 다시 시도합니다.",
            "Cloud": "클라우드",
            "On This Mac": "이 Mac에서",
            "Recommended": "권장",
            "This model will become active when the download finishes.": "다운로드가 완료되면 이 모델이 활성화됩니다.",
            "This removes the downloaded Local AI model. You can download it again later.": "다운로드한 로컬 AI 모델을 삭제합니다. 나중에 다시 다운로드할 수 있습니다.",
            "Cancel Local AI model download": "로컬 AI 모델 다운로드 취소",
            "Cloud fallback is only used when Post-processing uses a cloud model.": "클라우드 fallback은 후처리에서 클라우드 모델을 사용할 때만 적용됩니다.",
            "Local Context reads app and window text and analyzes screenshots on this Mac. Screenshots never leave this Mac.": "로컬 Context는 앱과 창의 텍스트를 읽고 스크린샷을 이 Mac에서 분석합니다. 스크린샷은 이 Mac을 벗어나지 않습니다.",
            "Best quality. Needs more memory.": "최고 품질입니다. 더 많은 메모리가 필요합니다.",
            "The previously selected on-device model is no longer available. Explicitly select Qwen2.5 7B to continue locally.": "이전에 선택한 온디바이스 모델을 더 이상 사용할 수 없습니다. 로컬에서 계속하려면 Qwen2.5 7B를 직접 선택하세요.",
            "The previously selected on-device model is no longer available. Context requires an image-capable model.": "이전에 선택한 온디바이스 모델을 더 이상 사용할 수 없습니다. Context에는 이미지 지원 모델이 필요합니다.",
            "Previously selected on-device model": "이전에 선택한 온디바이스 모델",
            "This on-device model is no longer available and cannot be used.": "이 온디바이스 모델은 더 이상 제공되지 않으며 사용할 수 없습니다.",
            "Canceled": "취소됨",
            "Selected": "선택됨",
            "Not selected": "선택되지 않음",
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

    private static func testMeetingSummaryCopyLocalizes() throws {
        let bundle = try compiledLocalizationBundle()
        let expected: [String: String] = [
            "Meeting Summary": "회의 요약",
            "Create a reviewable summary from completed transcripts.":
                "완료된 전사문으로 검토 가능한 회의 요약을 만듭니다.",
            "Meeting Summary is off. Existing summaries are kept.":
                "회의 요약이 꺼져 있습니다. 기존 요약은 유지됩니다.",
            "Meeting Summary is on, but cloud summarization is unavailable until an API key is configured.":
                "회의 요약이 켜져 있지만 API Key를 설정하기 전에는 클라우드 요약을 사용할 수 없습니다.",
            "Transcript": "전사문",
            "Summary": "요약",
            "Create Summary": "요약 만들기",
            "Regenerate Summary": "요약 다시 만들기",
            "Quick review draft": "빠른 검토 초안",
            "Generated from this transcript and calendar details. Review before sharing.":
                "이 전사문과 캘린더 세부 정보로 생성했습니다. 공유하기 전에 검토하세요.",
            "Transcript changed after this summary was generated.":
                "이 요약을 생성한 뒤 전사문이 변경되었습니다.",
            "Meeting Summary is off": "회의 요약이 꺼져 있습니다",
            "This saved summary is still available. Turn the feature on to regenerate it.":
                "저장된 요약은 계속 볼 수 있습니다. 다시 생성하려면 기능을 켜세요.",
            "Summary model is unavailable.": "요약 모델을 사용할 수 없습니다.",
            "No summary text to copy.": "복사할 요약 텍스트가 없습니다.",
            "Open Model Settings": "모델 설정 열기",
            "Overview": "개요",
            "Key Points": "핵심 내용",
            "Decisions": "결정 사항",
            "Action Items": "할 일",
            "Open Questions": "미해결 질문",
            "View in Transcript": "전사문에서 보기",
            "Owner needs review": "담당자 확인 필요",
            "Due date needs review": "기한 확인 필요",
            "Delete Summary": "요약 삭제",
            "Delete this summary?": "이 요약을 삭제할까요?",
            "This removes the saved meeting summary. You can create a new one from the transcript.":
                "저장된 회의 요약을 삭제합니다. 전사문에서 새로 만들 수 있습니다.",
            "Could not delete summary.": "요약을 삭제하지 못했습니다.",
            "Meeting Summary is off. Turn it on in Model Settings to create a summary.":
                "회의 요약이 꺼져 있습니다. 모델 설정에서 켜면 요약을 만들 수 있습니다.",
            "Summary service unavailable": "요약 서비스를 사용할 수 없음",
            "The selected provider could not create a meeting summary right now.":
                "선택한 제공자가 지금은 회의 요약을 만들지 못했습니다.",
            "Try Regenerate again later, or choose another configured model in Meeting Summary settings.":
                "잠시 후 다시 만들기를 시도하거나, 회의 요약 설정에서 다른 모델을 선택하세요.",
            "Summary response could not be read": "요약 응답을 읽을 수 없음",
            "Retry Summary": "요약 재시도",
            "Some evidence could not be verified.": "일부 근거를 확인하지 못했습니다.",
            "Review the summary before sharing it.": "공유하기 전에 요약을 검토하세요.",
            "Summary language could not be determined": "요약 언어를 확인할 수 없습니다",
            "The provider returned a response Quill could not use for the summary.":
                "제공자가 Quill에서 요약에 사용할 수 없는 응답을 반환했습니다.",
            "Try Regenerate again. If it continues, check the provider configuration.":
                "다시 만들기를 시도하세요. 계속되면 제공자 설정을 확인하세요."
        ]

        for (key, korean) in expected {
            assert(localizedCatalogString(key, language: "en", bundle: bundle) == key)
            assert(localizedCatalogString(key, language: "ko", bundle: bundle) == korean)
        }
    }

    private static func testModelDownloadTerminationCopyLocalizes() throws {
        let bundle = try compiledLocalizationBundle()
        let expected: [String: String] = [
            "Quit while models are downloading?": "모델 다운로드가 진행 중입니다. Quill을 종료할까요?",
            "Quill will cancel unfinished model downloads and delete partial files before quitting.":
                "종료하면 완료되지 않은 모델 다운로드가 취소되고 부분 다운로드 파일이 삭제됩니다.",
            "Quit and Cancel Downloads": "종료하고 다운로드 취소"
        ]

        for (key, korean) in expected {
            assert(localizedCatalogString(key, language: "en", bundle: bundle) == key)
            assert(localizedCatalogString(key, language: "ko", bundle: bundle) == korean)
        }
    }

    private static func testCombinedAudioSourceUnavailableReasonsLocalize() throws {
        let bundle = try compiledLocalizationBundle()
        let expected: [String: String] = [
            "Realtime is unavailable with Microphone + System Audio":
                "실시간은 마이크 + 시스템 오디오에서 사용할 수 없습니다",
            "Apple Live is unavailable with Microphone + System Audio":
                "Apple 라이브는 마이크 + 시스템 오디오에서 사용할 수 없습니다",
            "Microphone + System Audio": "마이크 + 시스템 오디오",
            "%@ + System Audio": "%@ + 시스템 오디오",
            "Used for Microphone and Microphone + System Audio.":
                "마이크 및 마이크 + 시스템 오디오에 사용됩니다."
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
