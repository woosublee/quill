import Foundation

extension PipelineHistoryItem {
    var meetingSummary: MeetingSummaryEnvelope? {
        guard let meetingSummaryJSON else { return nil }
        return try? JSONDecoder().decode(
            MeetingSummaryEnvelope.self,
            from: meetingSummaryJSON
        )
    }

    func withMeetingSummary(
        _ summary: MeetingSummaryEnvelope?
    ) -> PipelineHistoryItem {
        let encoded = summary.flatMap { try? JSONEncoder().encode($0) }
        return copying(
            meetingSummaryJSON: encoded,
            spokenLanguageCode: spokenLanguageCode,
            spokenLanguageResolution: spokenLanguageResolution,
            meetingSummaryAttempt: meetingSummaryAttempt,
            customTitle: customTitle,
            postProcessedTranscript: postProcessedTranscript
        )
    }

    func withMeetingSummaryAttempt(
        _ attempt: MeetingSummaryAttempt?
    ) -> PipelineHistoryItem {
        copying(
            meetingSummaryJSON: meetingSummaryJSON,
            spokenLanguageCode: spokenLanguageCode,
            spokenLanguageResolution: spokenLanguageResolution,
            meetingSummaryAttempt: attempt,
            customTitle: customTitle,
            postProcessedTranscript: postProcessedTranscript
        )
    }
}

extension MeetingSummaryContent {
    /// The summary text a person can read on the Summary tab, joined for search.
    var searchableText: String {
        var parts = [overview.text]
        parts += keyPoints.map(\.text)
        parts += decisions.map(\.text)
        for item in actionItems {
            parts.append(item.task)
            if let owner = item.owner { parts.append(owner) }
            if let dueDate = item.dueDate { parts.append(dueDate) }
        }
        parts += openQuestions.map(\.text)
        return parts.joined(separator: "\n")
    }
}

/// Matches notes against the Note Browser search text. It checks the title,
/// calendar title, processed transcript, and saved meeting summary; the raw
/// transcript is not searched because the detail view does not show it.
/// Decoded summary text is cached per note and reused while the stored JSON
/// is unchanged, so typing does not decode every summary on each keystroke.
final class NoteSearchMatcher {
    private var summaryTextCache: [UUID: (json: Data, text: String)] = [:]

    func matches(_ item: PipelineHistoryItem, query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        if Self.contains(item.customTitle, query)
            || Self.contains(item.calendarMatch?.title, query)
            || Self.contains(item.postProcessedTranscript, query) {
            return true
        }
        return Self.contains(summaryText(for: item), query)
    }

    /// Drops cached summary text for notes that no longer exist, so a
    /// deleted note's summary doesn't linger in memory.
    func retainCache(for ids: Set<UUID>) {
        summaryTextCache = summaryTextCache.filter { ids.contains($0.key) }
    }

    /// Drops all cached summary text, for example when search is cleared.
    func clearCache() {
        summaryTextCache.removeAll()
    }

    var cachedNoteCount: Int { summaryTextCache.count }

    private func summaryText(for item: PipelineHistoryItem) -> String? {
        guard let json = item.meetingSummaryJSON else {
            summaryTextCache[item.id] = nil
            return nil
        }
        if let cached = summaryTextCache[item.id], cached.json == json {
            return cached.text
        }
        let text = item.meetingSummary?.content.searchableText ?? ""
        summaryTextCache[item.id] = (json, text)
        return text
    }

    private static func contains(_ text: String?, _ query: String) -> Bool {
        guard let text, !text.isEmpty else { return false }
        return text.range(
            of: query,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) != nil
    }
}
