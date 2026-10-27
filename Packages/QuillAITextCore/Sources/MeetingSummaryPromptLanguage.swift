import Foundation

/// The summary language name a prompt asks for, or nil to keep the
/// transcript's language.
public enum MeetingSummaryPromptLanguage {
    /// The language code a summary language setting asks for, or nil when
    /// the setting is empty or unknown and the summary follows the spoken
    /// language. Every code here is one `SpokenLanguageResolver` can return.
    public static func code(forSetting setting: String?) -> String? {
        switch setting {
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
