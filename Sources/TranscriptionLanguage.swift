import Foundation
import QuillAITextCore
import Speech

struct TranscriptionLanguage: Identifiable, Hashable, Codable {
    let code: String      // mlx-whisper에 넘기는 언어 코드 (e.g. "ko")
    let displayName: String  // Stable fallback display name; `code` remains the persisted/API value.

    var id: String { code }

    func localizedDisplayName(
        language: String = preferredLocalizedStringLanguage(),
        bundle: Bundle = .main
    ) -> String {
        let key: String
        switch code {
        case "auto": key = "Auto Detect"
        case "ko": key = "Korean"
        case "en": key = "English"
        case "ja": key = "Japanese"
        case "zh": key = "Chinese"
        case "es": key = "Spanish"
        case "fr": key = "French"
        case "de": key = "German"
        default: return displayName
        }
        return localizedCatalogString(key, language: language, bundle: bundle)
    }

    // 자동 감지 옵션
    static let auto = TranscriptionLanguage(code: "auto", displayName: "Auto Detect")

    // 지원 언어 목록 — 언어를 추가하면 Packages/QuillAITextCore의
    // SpokenLanguageResolver.supportedCodes에도 추가한다(SpokenLanguageResolutionTests가 일치를 확인).
    static let all: [TranscriptionLanguage] = [
        .auto,
        TranscriptionLanguage(code: "ko", displayName: "한국어"),
        TranscriptionLanguage(code: "en", displayName: "English"),
        TranscriptionLanguage(code: "ja", displayName: "日本語"),
        TranscriptionLanguage(code: "zh", displayName: "中文"),
        TranscriptionLanguage(code: "es", displayName: "Español"),
        TranscriptionLanguage(code: "fr", displayName: "Français"),
        TranscriptionLanguage(code: "de", displayName: "Deutsch"),
    ]

    static func find(code: String) -> TranscriptionLanguage {
        all.first { $0.code == code } ?? .auto
    }

    static func code(forSummaryOutput outputLanguage: String?) -> String? {
        switch outputLanguage {
        case "Korean": "ko"
        case "English": "en"
        case "Japanese": "ja"
        case "Chinese": "zh"
        case "Spanish": "es"
        case "French": "fr"
        case "German": "de"
        case "Portuguese": "pt"
        default: nil
        }
    }

    static func summaryPromptLanguage(for code: String?) -> String? {
        MeetingSummaryPromptLanguage.name(for: code)
    }

    static func localizedSummaryLanguageName(
        for code: String,
        language: String = preferredLocalizedStringLanguage(),
        bundle: Bundle = .main
    ) -> String? {
        guard let key = summaryPromptLanguage(for: code) else { return nil }
        return localizedCatalogString(key, language: language, bundle: bundle)
    }

    // mlx-whisper에 넘길 인자값 (auto이면 language 옵션 생략)
    var whisperArgument: String? {
        code == "auto" ? nil : code
    }

    // SFSpeechRecognizer에 넘길 Locale (auto이면 시스템 언어 사용)
    // 언어 코드만 있는 경우 SFSpeechRecognizer가 지원하는 전체 로케일 중 가장 근접한 것을 선택
    var sfSpeechLocale: Locale {
        if code == "auto" { return .current }
        let requested = Locale(identifier: code)
        let supported = SFSpeechRecognizer.supportedLocales()
        // 정확히 일치하는 로케일이 있으면 그대로 사용
        if supported.contains(requested) { return requested }
        // 언어 코드가 같은 로케일 중 첫 번째 선택 (예: "ko" → "ko-KR")
        let lang = requested.language.languageCode?.identifier ?? code
        return supported.first { $0.language.languageCode?.identifier == lang } ?? requested
    }
}

struct RealtimeTranscriptionLanguageConfiguration: Equatable, Sendable {
    let requestLanguage: String?
    let requestedLanguageCode: String

    init(transcriptionLanguage: TranscriptionLanguage) {
        let requestLanguage = transcriptionLanguage.whisperArgument
        self.requestLanguage = requestLanguage
        self.requestedLanguageCode = requestLanguage ?? "auto"
    }
}
