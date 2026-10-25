import Foundation
import NaturalLanguage

public enum AIOutputLanguageValidation: Equatable, Sendable {
    case notRequested
    case accepted
    case uncertain
    case mismatch
}

public struct AIOutputLanguageValidator: Sendable {
    private enum SourceScript: Hashable {
        case latin
        case hangul
        case eastAsian
    }

    private let expectedLanguages: Set<NLLanguage>?

    public init(
        outputLanguage: String?,
        expectedSourceLanguage: String? = nil
    ) {
        if let configuredLanguages = Self.languages(for: outputLanguage) {
            expectedLanguages = configuredLanguages
        } else if Self.isAutomaticOutputLanguage(outputLanguage) {
            expectedLanguages = Self.languages(for: expectedSourceLanguage)
        } else {
            expectedLanguages = nil
        }
    }

    public static func expectedSourceLanguage(
        outputLanguage: String?,
        spokenLanguage: SpokenLanguageResolution?,
        fallbackSource: String
    ) -> String? {
        guard isAutomaticOutputLanguage(outputLanguage) else { return nil }
        switch spokenLanguage?.source {
        case .configured, .engineDetected:
            return SpokenLanguageResolver.supportedCode(spokenLanguage?.languageCode)
        case .transcriptInferred, .unavailable, nil:
            return inferredSourceLanguage(for: fallbackSource)
        }
    }

    public static func inferredSourceLanguage(for source: String) -> String? {
        let prose = ProtectedAtomScanner.removingAtoms(from: source)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let proseCharacterCount = prose.unicodeScalars.reduce(into: 0) { count, scalar in
            if CharacterSet.letters.contains(scalar) {
                count += 1
            }
        }
        guard proseCharacterCount >= 16,
              !hasSubstantialMixedScripts(in: prose) else {
            return nil
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(prose)
        guard let (language, confidence) = recognizer.languageHypotheses(
            withMaximum: 1
        ).first,
        confidence >= 0.85 else {
            return nil
        }
        return SpokenLanguageResolver.supportedCode(language.rawValue)
    }

    public func validate(generatedProse: String) -> AIOutputLanguageValidation {
        guard let expectedLanguages else { return .notRequested }

        let prose = ProtectedAtomScanner.removingAtoms(from: generatedProse)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard prose.rangeOfCharacter(from: .letters) != nil else {
            return .uncertain
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(prose)
        guard let detectedLanguage = recognizer.dominantLanguage else {
            return .uncertain
        }
        return expectedLanguages.contains(detectedLanguage) ? .accepted : .mismatch
    }

    public static func isAutomaticOutputLanguage(_ outputLanguage: String?) -> Bool {
        let language = outputLanguage?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        return language.isEmpty || language == "auto"
    }

    private static func languages(for outputLanguage: String?) -> Set<NLLanguage>? {
        switch SpokenLanguageResolver.supportedCode(outputLanguage) {
        case "ko":
            [.korean]
        case "en":
            [.english]
        case "ja":
            [.japanese]
        case "zh":
            [.simplifiedChinese, .traditionalChinese]
        case "zh-Hans":
            [.simplifiedChinese]
        case "zh-Hant":
            [.traditionalChinese]
        case "es":
            [.spanish]
        case "fr":
            [.french]
        case "de":
            [.german]
        case "pt":
            [.portuguese]
        default:
            nil
        }
    }

    private static func hasSubstantialMixedScripts(in text: String) -> Bool {
        var counts: [SourceScript: Int] = [:]
        for scalar in text.unicodeScalars {
            guard CharacterSet.letters.contains(scalar),
                  let script = sourceScript(for: scalar) else {
                continue
            }
            counts[script, default: 0] += 1
        }

        let total = counts.values.reduce(0, +)
        guard total > 0 else { return false }
        return counts.values.filter { $0 * 8 >= total }.count > 1
    }

    private static func sourceScript(for scalar: Unicode.Scalar) -> SourceScript? {
        switch scalar.value {
        case 0x0041...0x024F:
            .latin
        case 0x1100...0x11FF, 0xAC00...0xD7AF:
            .hangul
        case 0x3040...0x30FF, 0x3400...0x9FFF, 0xF900...0xFAFF:
            .eastAsian
        default:
            nil
        }
    }

}
