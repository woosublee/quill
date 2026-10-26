import Foundation

/// The summary language name a prompt asks for, or nil to keep the
/// transcript's language.
public enum MeetingSummaryPromptLanguage {
    public static func name(for code: String?) -> String? {
        switch code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "ko": "Korean"
        case "en": "English"
        case "ja": "Japanese"
        case "zh": "Chinese"
        case "zh-hans", "zh-cn", "zh-sg": "Simplified Chinese"
        case "zh-hant", "zh-hk", "zh-mo", "zh-tw": "Traditional Chinese"
        case "es": "Spanish"
        case "fr": "French"
        case "de": "German"
        case "pt", "pt-br", "pt-pt": "Portuguese"
        default: nil
        }
    }
}
