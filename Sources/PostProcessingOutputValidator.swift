import Foundation

enum AIValidationFailure: Error, Codable, Equatable, Sendable {
    case nonFillerEmpty
    case languageMismatch
    case languageUncertain
    case protectedAtomMissing
    case promptLeak
    case instructionExecution
    case disproportionateCollapse
}

enum AIProcessingOutcome: Codable, Equatable, Sendable {
    case succeeded
    case rawFallback(reason: AIValidationFailure)
    case failed(reason: String)
}

struct PostProcessingOutputValidator {
    private static let normalizedDataEnvelopePromptLeakSignatures =
        PostProcessingPromptPolicy.leakSignatures.map(normalizedPromptLeakText)

    static func containsPostProcessingPromptLeak(
        output: String,
        source: String
    ) -> Bool {
        if output.contains("<<<RAW_TRANSCRIPTION") {
            return true
        }

        let normalizedOutput = normalizedPromptLeakText(output)
        let normalizedSource = normalizedPromptLeakText(source)
        return normalizedDataEnvelopePromptLeakSignatures.contains { signature in
            normalizedOutput.contains(signature)
                && !normalizedSource.contains(signature)
        }
    }

    private static func normalizedPromptLeakText(_ value: String) -> String {
        let alphanumericText = value.lowercased().unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : " "
        }.joined()
        return alphanumericText
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    func validate(
        source: String,
        output: String,
        outputLanguage: String,
        expectedSourceLanguage: String? = nil,
        vocabulary: [String],
        correctionHeardForms: [String] = []
    ) -> Result<String, AIValidationFailure> {
        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedOutput.isEmpty || trimmedOutput == "EMPTY" {
            return isMeaningful(source) ? .failure(.nonFillerEmpty) : .success("")
        }
        if Self.containsPostProcessingPromptLeak(
            output: trimmedOutput,
            source: source
        ) {
            return .failure(.promptLeak)
        }

        // A misheard form the user asked to correct (for example
        // `quill_app -> Quill`) is meant to change, so it isn't protected.
        let heardForms = correctionHeardForms.map { $0.lowercased() }
        let sourceProtectedAtoms = ProtectedAtomScanner.atoms(
            from: source,
            vocabulary: vocabulary
        ).filter { atom in
            let lowered = atom.lowercased()
            return !heardForms.contains { $0 == lowered || $0.contains(lowered) }
        }
        if sourceProtectedAtoms.contains(where: { !trimmedOutput.contains($0) }) {
            return .failure(.protectedAtomMissing)
        }

        let sourceProse = ProtectedAtomScanner.removingAtoms(
            from: source,
            atoms: sourceProtectedAtoms
        )
        if sourceProse.rangeOfCharacter(from: .letters) != nil {
            switch AIOutputLanguageValidator(
                outputLanguage: outputLanguage,
                expectedSourceLanguage: expectedSourceLanguage
            ).validate(generatedProse: trimmedOutput) {
            case .mismatch:
                return .failure(.languageMismatch)
            case .uncertain:
                return .failure(.languageUncertain)
            case .accepted, .notRequested:
                break
            }
        }

        if isDisproportionatelyCollapsed(source: source, output: trimmedOutput) {
            return .failure(.disproportionateCollapse)
        }
        return .success(trimmedOutput)
    }

    /// Minimum transcript length, counted without whitespace or punctuation,
    /// before an empty or `EMPTY` cleanup reply is worth asking about again.
    static let emptyReplyReaskMinimumCharacterCount = 40

    /// Decides whether an empty or `EMPTY` cleanup reply should be re-asked once.
    /// Only non-filler transcripts with at least
    /// `emptyReplyReaskMinimumCharacterCount` characters, ignoring whitespace
    /// and punctuation, qualify.
    static func shouldReaskAfterEmptyReply(source: String) -> Bool {
        guard isMeaningful(source) else { return false }
        let ignored = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        let count = source.reduce(into: 0) { count, character in
            if !character.unicodeScalars.allSatisfy({ ignored.contains($0) }) {
                count += 1
            }
        }
        return count >= emptyReplyReaskMinimumCharacterCount
    }

    private func isMeaningful(_ source: String) -> Bool {
        Self.isMeaningful(source)
    }

    private static func isMeaningful(_ source: String) -> Bool {
        let withoutFillers = source.replacingOccurrences(
            of: #"(?i)\b(?:um+|uh+|erm|er|ah+|eh+|yeah|yep|well|okay|ok|so)\b|(?:음+|어+|저기)"#,
            with: " ",
            options: .regularExpression
        )
        return withoutFillers.rangeOfCharacter(
            from: CharacterSet.letters.union(.decimalDigits)
        ) != nil
    }

    private func isDisproportionatelyCollapsed(source: String, output: String) -> Bool {
        let sourceProseCount = proseCharacterCount(in: source)
        guard sourceProseCount >= 240 else { return false }
        return proseCharacterCount(in: output) * 6 < sourceProseCount
    }

    private func proseCharacterCount(in text: String) -> Int {
        text.unicodeScalars.reduce(into: 0) { count, scalar in
            if CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) {
                count += 1
            }
        }
    }
}

extension AIProcessingOutcome {
    var pipelineHistoryStatus: String {
        switch self {
        case .succeeded:
            return "succeeded"
        case .rawFallback(let reason):
            return "raw-fallback:\(String(describing: reason))"
        case .failed(let reason):
            return "failed:\(reason)"
        }
    }
}
