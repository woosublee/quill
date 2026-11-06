import Foundation

/// The tags on a note's detail meta line, the same on the Mac and the
/// iPhone (#697): "LOCAL · NO CTX · LLM · KO", or "Audio only" first for a
/// note that wasn't transcribed. A tag that's off (CLOUD, NO CTX, NO LLM)
/// draws dimmer. VoiceOver reads the tags in words, not the abbreviations.
///
/// The tags themselves aren't translated, except "Audio only". Each app
/// translates the keys with its own String Catalog and draws the line.
public struct NoteMetaTags: Equatable, Sendable {
    public struct Tag: Equatable, Sendable {
        /// The tag's text.
        public let label: Label
        /// False for a feature that was off; it draws dimmer.
        public let isActive: Bool
        /// The tooltip's copy key (Mac).
        public let helpKey: String
        /// What VoiceOver reads for it.
        public let spoken: Spoken
    }

    /// A tag's text: shown as is ("LOCAL"), or a copy key to translate
    /// ("Audio only").
    public enum Label: Equatable, Sendable {
        case verbatim(String)
        case key(String)
    }

    /// A tag in words.
    public enum Spoken: Equatable, Sendable {
        /// A copy key.
        case key(String)
        /// "Transcription language: %@" with the code.
        case transcriptionLanguage(String)

        public static let transcriptionLanguageFormatKey = "Transcription language: %@"
    }

    public let tags: [Tag]

    /// - Parameter languageCode: The fixed transcription language. "auto",
    ///   nil, or a blank code shows no language tag.
    public init(
        isAudioOnly: Bool,
        usedLocalTranscription: Bool,
        usedContextCapture: Bool,
        usedPostProcessing: Bool,
        languageCode: String?
    ) {
        var tags: [Tag] = []
        if isAudioOnly {
            tags.append(Tag(
                label: .key("Audio only"), isActive: true,
                helpKey: "Audio-only recording", spoken: .key("Audio-only recording")
            ))
        } else {
            let key = usedLocalTranscription ? "Local transcription" : "Cloud transcription"
            tags.append(Tag(
                label: .verbatim(usedLocalTranscription ? "LOCAL" : "CLOUD"),
                isActive: usedLocalTranscription, helpKey: key, spoken: .key(key)
            ))
        }
        let contextKey = usedContextCapture ? "Context capture enabled" : "Context capture disabled"
        tags.append(Tag(
            label: .verbatim(usedContextCapture ? "CTX" : "NO CTX"),
            isActive: usedContextCapture, helpKey: contextKey, spoken: .key(contextKey)
        ))
        let llmKey = usedPostProcessing ? "LLM post-processing enabled" : "LLM post-processing disabled"
        tags.append(Tag(
            label: .verbatim(usedPostProcessing ? "LLM" : "NO LLM"),
            isActive: usedPostProcessing, helpKey: llmKey, spoken: .key(llmKey)
        ))
        if let code = Self.languageTag(languageCode) {
            tags.append(Tag(
                label: .verbatim(code), isActive: true,
                helpKey: "Transcription language", spoken: .transcriptionLanguage(code)
            ))
        }
        self.tags = tags
    }

    /// The language tag's text, or nil when the language isn't fixed.
    public static func languageTag(_ code: String?) -> String? {
        let trimmed = (code ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "auto" else { return nil }
        return trimmed.uppercased()
    }

    /// Every copy key the tags can use, for catalog checks.
    public static let allCopyKeys: [String] = [
        "Audio only", "Audio-only recording",
        "Local transcription", "Cloud transcription",
        "Context capture enabled", "Context capture disabled",
        "LLM post-processing enabled", "LLM post-processing disabled",
        "Transcription language", Spoken.transcriptionLanguageFormatKey
    ]
}
