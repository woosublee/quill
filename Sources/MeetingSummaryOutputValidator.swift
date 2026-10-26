import Foundation
import QuillAITextCore
import QuillUserIssueCore
import QuillSummaryFormatCore

enum MeetingSummaryOutputValidationError: Error, Equatable, Sendable {
    case sourceQuoteMissing
    case overviewEvidenceCountInvalid
    case overviewEvidenceQuoteDuplicate
    case sourceQuoteNotFound
    case ownerNotGrounded
    case dueDateNotGrounded
    case languageMismatch

    var failureSubtype: MeetingSummaryFailureSubtype {
        switch self {
        case .sourceQuoteMissing:
            .sourceEvidenceMissing
        case .overviewEvidenceCountInvalid:
            .overviewEvidenceCountInvalid
        case .overviewEvidenceQuoteDuplicate:
            .overviewEvidenceQuoteDuplicate
        case .sourceQuoteNotFound:
            .sourceQuoteNotFound
        case .ownerNotGrounded:
            .ownerNotGrounded
        case .dueDateNotGrounded:
            .dueDateNotGrounded
        case .languageMismatch:
            .languageMismatch
        }
    }
}

private enum MeetingSummaryDateEvidenceMatcher {
    static func containsDateNormalized(
        _ dueDate: String,
        in sourceQuote: String
    ) -> Bool {
        let normalizedDueDate = normalizedWhitespace(dueDate)
        let normalizedSourceQuote = normalizedWhitespace(sourceQuote)
        if normalizedSourceQuote.range(of: normalizedDueDate, options: .literal) != nil {
            return true
        }
        guard let dueDateValue = parseDate(normalizedDueDate) else {
            return false
        }
        return dateStrings(in: normalizedSourceQuote).contains { candidate in
            parseDate(candidate) == dueDateValue
        }
    }

    private static func dateStrings(in text: String) -> [String] {
        let patterns = [
            #"\b\d{4}-\d{2}-\d{2}(?:T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z)?\b"#,
            #"\b(?:January|February|March|April|May|June|July|August|September|October|November|December)\s+\d{1,2},?\s+\d{4}\b"#,
            #"\b(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)\.?\s+\d{1,2},?\s+\d{4}\b"#,
            #"(?<!\d)\d{4}\s*년\s*\d{1,2}\s*월\s*\d{1,2}\s*일(?!\d)"#,
            #"(?<!\d)\d{4}\s*年\s*\d{1,2}\s*月\s*\d{1,2}\s*日(?!\d)"#
        ]
        return patterns.flatMap { pattern in
            guard let expression = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive]
            ) else {
                return [String]()
            }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            return expression.matches(in: text, range: range).compactMap {
                Range($0.range, in: text).map { String(text[$0]) }
            }
        }
    }

    private static func parseDate(_ value: String) -> String? {
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: value) {
            return dayFormatter.string(from: date)
        }
        if let date = localizedGregorianDate(from: value) {
            return dayFormatter.string(from: date)
        }
        for format in [
            "yyyy-MM-dd",
            "MMMM d, yyyy",
            "MMMM d yyyy",
            "MMM d, yyyy",
            "MMM d yyyy"
        ] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return dayFormatter.string(from: date)
            }
        }
        return nil
    }

    private static func localizedGregorianDate(from value: String) -> Date? {
        let pattern = #"^(\d{4})\s*(?:년|年)\s*(\d{1,2})\s*(?:월|月)\s*(\d{1,2})\s*(?:일|日)$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: value,
                range: NSRange(value.startIndex..<value.endIndex, in: value)
              ),
              match.range.location == 0,
              match.range.length == (value as NSString).length else {
            return nil
        }
        let components = (1...3).compactMap { index -> Int? in
            guard let range = Range(match.range(at: index), in: value) else {
                return nil
            }
            return Int(value[range])
        }
        guard components.count == 3 else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var dateComponents = DateComponents()
        dateComponents.calendar = calendar
        dateComponents.timeZone = calendar.timeZone
        dateComponents.year = components[0]
        dateComponents.month = components[1]
        dateComponents.day = components[2]
        guard let date = calendar.date(from: dateComponents) else { return nil }
        let resolved = calendar.dateComponents([.year, .month, .day], from: date)
        guard resolved.year == components[0],
              resolved.month == components[1],
              resolved.day == components[2] else {
            return nil
        }
        return date
    }

    private static var dayFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    private static func normalizedWhitespace(_ value: String) -> String {
        value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

struct MeetingSummaryOutputValidator: Sendable {
    func validate(
        _ draft: MeetingSummaryDraftContentV2,
        outputLanguage: String = "",
        against transcript: String
    ) throws {
        try validate(
            draft,
            outputLanguage: outputLanguage,
            sourceTexts: [transcript]
        )
    }

    func validate(
        _ draft: MeetingSummaryDraftContentV2,
        outputLanguage: String = "",
        against source: SummarySourceData
    ) throws {
        try validate(
            draft,
            outputLanguage: outputLanguage,
            sourceTexts: Self.sourceTexts(for: source)
        )
    }

    func validate(
        _ draft: MeetingSummaryDraftContentV2,
        outputLanguage: String = "",
        againstValidatedRecords records: [MeetingSummaryDraftContentV2]
    ) throws {
        try validate(
            draft,
            outputLanguage: outputLanguage,
            sourceTexts: records.flatMap(\.validatedSourceTexts)
        )
    }

    private func validate(
        _ draft: MeetingSummaryDraftContentV2,
        outputLanguage: String,
        sourceTexts: [String]
    ) throws {
        let sources = sourceTexts.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        try validateOverviewEvidence(
            draft.overview.sourceQuotes,
            sources: sources
        )
        for point in draft.keyPoints + draft.decisions + draft.openQuestions {
            try validate(sourceQuotes: [point.sourceQuote], sources: sources)
        }
        for action in draft.actionItems {
            try validate(sourceQuotes: [action.sourceQuote], sources: sources)
            guard let sourceQuote = action.sourceQuote else {
                throw MeetingSummaryOutputValidationError.sourceQuoteMissing
            }
            if let owner = nonempty(action.owner),
               !containsWhitespaceNormalized(owner, in: sourceQuote) {
                throw MeetingSummaryOutputValidationError.ownerNotGrounded
            }
            if let dueDate = nonempty(action.dueDate),
               !MeetingSummaryDateEvidenceMatcher.containsDateNormalized(
                dueDate,
                in: sourceQuote
               ) {
                throw MeetingSummaryOutputValidationError.dueDateNotGrounded
            }
        }

        switch AIOutputLanguageValidator(outputLanguage: outputLanguage).validate(
            generatedProse: generatedProse(from: draft)
        ) {
        case .mismatch:
            throw MeetingSummaryOutputValidationError.languageMismatch
        case .accepted, .notRequested, .uncertain:
            break
        }
    }

    private func validateOverviewEvidence(
        _ sourceQuotes: [String],
        sources: [String]
    ) throws {
        guard (1...2).contains(sourceQuotes.count) else {
            throw MeetingSummaryOutputValidationError.overviewEvidenceCountInvalid
        }
        let normalizedQuotes = sourceQuotes.compactMap(nonempty)
        guard normalizedQuotes.count == sourceQuotes.count else {
            throw MeetingSummaryOutputValidationError.sourceQuoteMissing
        }
        guard Set(normalizedQuotes).count == normalizedQuotes.count else {
            throw MeetingSummaryOutputValidationError.overviewEvidenceQuoteDuplicate
        }
        try validate(sourceQuotes: normalizedQuotes.map(Optional.some), sources: sources)
    }

    private func validate(
        sourceQuotes: [String?],
        sources: [String]
    ) throws {
        guard !sourceQuotes.isEmpty else {
            throw MeetingSummaryOutputValidationError.sourceQuoteMissing
        }
        for quote in sourceQuotes {
            guard let quote = nonempty(quote) else {
                throw MeetingSummaryOutputValidationError.sourceQuoteMissing
            }
            let membershipQuote = quote.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard sources.contains(where: { $0.range(of: membershipQuote, options: .literal) != nil }) else {
                throw MeetingSummaryOutputValidationError.sourceQuoteNotFound
            }
        }
    }

    private func generatedProse(
        from draft: MeetingSummaryDraftContentV2
    ) -> String {
        var prose = [draft.overview.text]
        prose.append(contentsOf: draft.keyPoints.map(\.text))
        prose.append(contentsOf: draft.decisions.map(\.text))
        prose.append(contentsOf: draft.actionItems.map(\.task))
        prose.append(contentsOf: draft.openQuestions.map(\.text))
        return prose.joined(separator: "\n")
    }

    private func containsWhitespaceNormalized(
        _ value: String,
        in sourceQuote: String
    ) -> Bool {
        normalizedQuote(sourceQuote).range(
            of: normalizedQuote(value),
            options: .literal
        ) != nil
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalizedQuote(_ value: String) -> String {
        value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func sourceTexts(for source: SummarySourceData) -> [String] {
        var texts = [source.transcript]
        guard let calendar = source.calendar else { return texts }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        texts.append(calendar.title)
        texts.append(formatter.string(from: calendar.start))
        texts.append(formatter.string(from: calendar.end))
        texts.append(contentsOf: calendar.attendees)
        return texts
    }

    func validateLanguage(
        _ draft: MeetingSummaryDraftContentV2,
        outputLanguage: String
    ) throws {
        switch AIOutputLanguageValidator(outputLanguage: outputLanguage).validate(
            generatedProse: generatedProse(from: draft)
        ) {
        case .mismatch:
            throw MeetingSummaryOutputValidationError.languageMismatch
        case .accepted, .notRequested, .uncertain:
            break
        }
    }
}

struct MeetingSummaryEvidenceRepairResult: Equatable, Sendable {
    let draft: MeetingSummaryDraftContentV2
    let verification: MeetingSummaryEvidenceVerification
}

/// Repairs only whitespace and punctuation variants by replacing a model quote
/// with the exact source substring. It never invents evidence or changes prose.
struct MeetingSummaryEvidenceRepairer: Sendable {
    func repair(
        _ draft: MeetingSummaryDraftContentV2,
        sourceTexts: [String]
    ) -> MeetingSummaryEvidenceRepairResult {
        let sources = sourceTexts.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        var isVerified = true

        func repairedQuote(_ quote: String?) -> String? {
            guard let quote = nonempty(quote),
                  let sourceQuote = matchingSourceSubstring(
                    for: quote,
                    in: sources
                  ) else {
                isVerified = false
                return quote
            }
            return sourceQuote
        }

        let overviewQuotes = draft.overview.sourceQuotes.map { repairedQuote($0) ?? $0 }
        if !(1...2).contains(overviewQuotes.count)
            || Set(overviewQuotes.map(normalized)).count != overviewQuotes.count {
            isVerified = false
        }
        let overview = MeetingSummaryEvidenceText(
            text: draft.overview.text,
            sourceQuotes: overviewQuotes
        )
        let points = (draft.keyPoints + draft.decisions + draft.openQuestions).map {
            MeetingSummaryPoint(
                id: $0.id,
                text: $0.text,
                sourceQuote: repairedQuote($0.sourceQuote)
            )
        }
        let keyPointCount = draft.keyPoints.count
        let decisionCount = draft.decisions.count
        let keyPoints = Array(points.prefix(keyPointCount))
        let decisions = Array(points.dropFirst(keyPointCount).prefix(decisionCount))
        let openQuestions = Array(points.dropFirst(keyPointCount + decisionCount))
        let actions = draft.actionItems.map { action -> MeetingSummaryActionItem in
            let sourceQuote = repairedQuote(action.sourceQuote)
            var owner = action.owner
            var dueDate = action.dueDate
            guard let sourceQuote else {
                owner = nil
                dueDate = nil
                return MeetingSummaryActionItem(
                    id: action.id,
                    task: action.task,
                    owner: owner,
                    dueDate: dueDate,
                    sourceQuote: sourceQuote,
                    isCompleted: action.isCompleted
                )
            }
            let normalizedSourceQuote = normalized(sourceQuote) ?? ""
            if let value = nonempty(owner),
               !normalizedSourceQuote.contains(normalized(value) ?? "") {
                owner = nil
                isVerified = false
            }
            if let value = nonempty(dueDate),
               !MeetingSummaryDateEvidenceMatcher.containsDateNormalized(
                value,
                in: sourceQuote
               ) {
                dueDate = nil
                isVerified = false
            }
            return MeetingSummaryActionItem(
                id: action.id,
                task: action.task,
                owner: owner,
                dueDate: dueDate,
                sourceQuote: sourceQuote,
                isCompleted: action.isCompleted
            )
        }
        return MeetingSummaryEvidenceRepairResult(
            draft: MeetingSummaryDraftContentV2(
                overview: overview,
                keyPoints: keyPoints,
                decisions: decisions,
                actionItems: actions,
                openQuestions: openQuestions
            ),
            verification: isVerified ? .verified : .unverified
        )
    }

    private func matchingSourceSubstring(
        for quote: String,
        in sources: [String]
    ) -> String? {
        for source in sources {
            if let exact = source.range(of: quote, options: .literal) {
                return String(source[exact])
            }
            guard let normalizedQuote = normalized(quote),
                  let range = normalizedSourceRange(
                    matching: normalizedQuote,
                    in: source
                  ) else {
                continue
            }
            return String(source[range])
        }
        return nil
    }

    private func normalizedSourceRange(
        matching quote: String,
        in source: String
    ) -> Range<String.Index>? {
        var normalizedSource = ""
        var ranges: [Range<String.Index>] = []
        var previousWasSpace = false
        var index = source.startIndex
        while index < source.endIndex {
            let next = source.index(after: index)
            let character = source[index]
            if isWhitespace(character) {
                if !previousWasSpace, !normalizedSource.isEmpty {
                    normalizedSource.append(" ")
                    ranges.append(index..<next)
                }
                previousWasSpace = true
            } else if let normalizedCharacters = normalizedCharacters(for: character) {
                for normalizedCharacter in normalizedCharacters {
                    normalizedSource.append(normalizedCharacter)
                    ranges.append(index..<next)
                }
                previousWasSpace = false
            }
            index = next
        }
        while normalizedSource.last == " " {
            normalizedSource.removeLast()
            ranges.removeLast()
        }
        guard let match = normalizedSource.range(of: quote, options: .literal) else {
            return nil
        }
        let lower = normalizedSource.distance(
            from: normalizedSource.startIndex,
            to: match.lowerBound
        )
        let upper = normalizedSource.distance(
            from: normalizedSource.startIndex,
            to: match.upperBound
        )
        guard lower < ranges.count, upper > 0, upper <= ranges.count else { return nil }
        var end = ranges[upper - 1].upperBound
        while end < source.endIndex {
            let next = source.index(after: end)
            let character = source[end]
            guard isWhitespace(character) || isPunctuation(character) else { break }
            end = next
        }
        return ranges[lower].lowerBound..<end
    }

    private func normalized(_ value: String) -> String? {
        let result = value.reduce(into: "") { result, character in
            if isWhitespace(character) {
                result.append(" ")
            } else if let normalizedCharacters = normalizedCharacters(for: character) {
                result.append(contentsOf: normalizedCharacters)
            }
        }
        let collapsedWhitespace = result
            .split(whereSeparator: { $0 == " " })
            .joined(separator: " ")
        return collapsedWhitespace.isEmpty ? nil : collapsedWhitespace
    }

    private func normalizedCharacters(for character: Character) -> String? {
        guard !isPunctuation(character) else { return nil }
        if String(character) == "İ" {
            return "i"
        }
        return String(character).lowercased()
    }

    private func isWhitespace(_ character: Character) -> Bool {
        String(character).unicodeScalars.contains { scalar in
            CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
    }

    private func isPunctuation(_ character: Character) -> Bool {
        String(character).unicodeScalars.allSatisfy(CharacterSet.punctuationCharacters.contains)
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
