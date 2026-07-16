import Foundation
import Speech

struct TranscriptionLanguage: Identifiable, Hashable, Codable {
    let code: String      // mlx-whisper에 넘기는 언어 코드 (e.g. "ko")
    let displayName: String  // Stable fallback display name; `code` remains the persisted/API value.

    var id: String { code }

    func localizedDisplayName(language: String = Locale.current.language.languageCode?.identifier ?? "en") -> String {
        let korean = language.lowercased().hasPrefix("ko")
        switch code {
        case "auto": return korean ? "자동 감지" : "Auto Detect"
        case "ko": return korean ? "한국어" : "Korean"
        case "en": return korean ? "영어" : "English"
        case "ja": return korean ? "일본어" : "Japanese"
        case "zh": return korean ? "중국어" : "Chinese"
        case "es": return korean ? "스페인어" : "Spanish"
        case "fr": return korean ? "프랑스어" : "French"
        case "de": return korean ? "독일어" : "German"
        default: return displayName
        }
    }

    // 자동 감지 옵션
    static let auto = TranscriptionLanguage(code: "auto", displayName: "Auto Detect")

    // 지원 언어 목록 — 언어 추가 시 여기에만 추가하면 됨
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
