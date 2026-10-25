import NaturalLanguage

enum SpokenLanguageResolutionSource: String, Codable, Equatable, Sendable, CaseIterable {
    case configured
    case engineDetected
    case transcriptInferred
    case unavailable
}

struct SpokenLanguageResolution: Codable, Equatable, Sendable {
    let languageCode: String?
    let source: SpokenLanguageResolutionSource
}

struct TranscriptionResult: Equatable, Sendable {
    let text: String
    let spokenLanguage: SpokenLanguageResolution
}

enum TranscriptTextNormalizer {
    static func normalized(
        _ text: String,
        removingTimestampPrefixes: Bool = false
    ) -> String {
        let source: String
        if removingTimestampPrefixes {
            source = text
                .split(separator: "\n")
                .map { line in
                    String(line).replacingOccurrences(
                        of: #"^\[[^\]]+\]\s*"#,
                        with: "",
                        options: .regularExpression
                    )
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        } else {
            source = text
        }
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let reducedPunctuation = trimmed.replacingOccurrences(
            of: #"([!?.,])\1+"#,
            with: #"$1"#,
            options: .regularExpression
        )
        let collapsedWhitespace = reducedPunctuation.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        let normalized = collapsedWhitespace.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let contentOnly = normalized.trimmingCharacters(
            in: CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines)
        )
        return contentOnly.isEmpty ? "" : normalized
    }
}

struct SpokenLanguageResolver {
    static func resolve(
        requestedLanguageCode: String,
        engineLanguageCode: String?,
        transcript: String
    ) -> SpokenLanguageResolution {
        if let configured = supportedCode(requestedLanguageCode) {
            return SpokenLanguageResolution(
                languageCode: configured,
                source: .configured
            )
        }
        if let detected = supportedCode(engineLanguageCode) {
            return SpokenLanguageResolution(
                languageCode: detected,
                source: .engineDetected
            )
        }
        if let inferred = inferredLanguageCode(for: transcript) {
            return SpokenLanguageResolution(
                languageCode: inferred,
                source: .transcriptInferred
            )
        }
        return SpokenLanguageResolution(
            languageCode: nil,
            source: .unavailable
        )
    }

    static func supportedCode(_ code: String?) -> String? {
        let normalized = code?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""

        let aliases = [
            "korean": "ko",
            "english": "en",
            "japanese": "ja",
            "chinese": "zh",
            "spanish": "es",
            "french": "fr",
            "german": "de",
            "portuguese": "pt",
        ]
        if let alias = aliases[normalized] {
            return alias
        }

        guard let primaryCode = validBCP47PrimaryCode(from: normalized) else {
            return nil
        }
        let supportedCodes = Set(
            TranscriptionLanguage.all.map(\.code).filter { $0 != "auto" }
        ).union(["pt"])
        guard supportedCodes.contains(primaryCode) else { return nil }
        return normalizedChineseCode(
            from: normalized,
            primaryCode: primaryCode
        )
    }

    private static func validBCP47PrimaryCode(from code: String) -> String? {
        let subtags = Array(code.split(separator: "-", omittingEmptySubsequences: false))
        guard let primary = subtags.first,
              primary.count == 2,
              isASCIILetters(primary)
        else {
            return nil
        }

        let suffixes = Array(subtags.dropFirst())
        guard suffixes.allSatisfy({ !$0.isEmpty }) else { return nil }
        switch suffixes.count {
        case 0:
            return String(primary)
        case 1 where isSupportedScriptSubtag(suffixes[0], for: primary) || isValidRegionSubtag(suffixes[0]):
            return String(primary)
        case 2 where isSupportedScriptSubtag(suffixes[0], for: primary) && isValidRegionSubtag(suffixes[1]):
            return String(primary)
        default:
            return nil
        }
    }

    private static func normalizedChineseCode(
        from normalizedCode: String,
        primaryCode: String
    ) -> String {
        guard primaryCode == "zh" else { return primaryCode }
        let suffixes = normalizedCode.split(separator: "-").dropFirst()
        if suffixes.contains("hant")
            || suffixes.contains(where: { ["hk", "mo", "tw"].contains(String($0)) }) {
            return "zh-Hant"
        }
        if suffixes.contains("hans")
            || suffixes.contains(where: { ["cn", "sg"].contains(String($0)) }) {
            return "zh-Hans"
        }
        return "zh"
    }

    private static func isSupportedScriptSubtag(_ subtag: Substring, for primaryCode: Substring) -> Bool {
        let supportedScripts = [
            "de": ["latn"],
            "en": ["latn"],
            "es": ["latn"],
            "fr": ["latn"],
            "ja": ["jpan"],
            "ko": ["kore"],
            "pt": ["latn"],
            "zh": ["hans", "hant"],
        ]
        return supportedScripts[String(primaryCode)]?.contains(String(subtag)) == true
    }

    private static func isValidRegionSubtag(_ subtag: Substring) -> Bool {
        guard (subtag.count == 2 && isASCIILetters(subtag)) ||
                (subtag.count == 3 && isASCIIDigits(subtag))
        else {
            return false
        }
        return Locale.Region.isoRegions.map(\.identifier).contains(String(subtag).uppercased())
    }

    private static func isASCIILetters(_ subtag: Substring) -> Bool {
        subtag.unicodeScalars.allSatisfy { scalar in
            (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
        }
    }

    private static func isASCIIDigits(_ subtag: Substring) -> Bool {
        subtag.unicodeScalars.allSatisfy { (48...57).contains($0.value) }
    }

    private static func inferredLanguageCode(for transcript: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(transcript)
        return supportedCode(recognizer.dominantLanguage?.rawValue)
    }
}
