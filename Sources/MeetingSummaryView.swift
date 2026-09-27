import SwiftUI

struct MeetingSummaryView<Notices: View>: View {
    let envelope: MeetingSummaryEnvelope
    let sourceQuoteIsValid: (String) -> Bool
    let onToggleAction: (UUID, Bool) -> Void
    let onViewSource: (String) -> Void
    /// One-line notices above the summary, such as a stale transcript.
    let notices: Notices

    init(
        envelope: MeetingSummaryEnvelope,
        sourceQuoteIsValid: @escaping (String) -> Bool,
        onToggleAction: @escaping (UUID, Bool) -> Void,
        onViewSource: @escaping (String) -> Void,
        @ViewBuilder notices: () -> Notices
    ) {
        self.envelope = envelope
        self.sourceQuoteIsValid = sourceQuoteIsValid
        self.onToggleAction = onToggleAction
        self.onViewSource = onViewSource
        self.notices = notices()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                notices
                summaryContent(envelope)
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.top, 14)
            .padding(.bottom, 96)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func summaryContent(
        _ envelope: MeetingSummaryEnvelope
    ) -> some View {
        let content = envelope.content
        return VStack(alignment: .leading, spacing: 24) {
            summarySection(title: "Overview") {
                Text(content.overview.text)
                    .font(.body)
                    .textSelection(.enabled)
            }
            pointSection(title: "Key Points", points: content.keyPoints)
            pointSection(title: "Decisions", points: content.decisions)
            actionSection(content.actionItems)
            pointSection(title: "Open Questions", points: content.openQuestions)
        }
    }

    private func pointSection(
        title: LocalizedStringKey,
        points: [MeetingSummaryPoint]
    ) -> some View {
        summarySection(title: title) {
            if points.isEmpty {
                Text("None")
                    .foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(points) { point in
                        evidenceRow(text: point.text, sourceQuote: point.sourceQuote)
                    }
                }
            }
        }
    }

    private func actionSection(
        _ actions: [MeetingSummaryActionItem]
    ) -> some View {
        summarySection(title: "Action Items") {
            if actions.isEmpty {
                Text("None")
                    .foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(actions) { item in
                        HStack(alignment: .top, spacing: 10) {
                            Toggle(
                                item.task,
                                isOn: Binding(
                                    get: { item.isCompleted },
                                    set: { onToggleAction(item.id, $0) }
                                )
                            )
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                            .accessibilityLabel(item.task)

                            VStack(alignment: .leading, spacing: 5) {
                                Text(item.task)
                                    .strikethrough(item.isCompleted)
                                    .foregroundStyle(
                                        item.isCompleted ? .secondary : .primary
                                    )
                                actionMetadata(item)
                                if let quote = nonempty(item.sourceQuote),
                                   sourceQuoteIsValid(quote) {
                                    sourceButton(quote)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
    }

    private func actionMetadata(_ item: MeetingSummaryActionItem) -> some View {
        let owner = nonempty(item.owner)
        let dueDate = nonempty(item.dueDate)
        return HStack(spacing: 8) {
            if let owner {
                Text(owner)
            } else {
                Text("Owner needs review")
            }
            Text("·")
                .foregroundStyle(.tertiary)
            if let dueDate {
                Text(dueDate)
            } else {
                Text("Due date needs review")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func evidenceRow(
        text: String,
        sourceQuote: String?
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(Color.secondary.opacity(0.45))
                .frame(width: 4, height: 4)
                .padding(.top, 8)
            VStack(alignment: .leading, spacing: 5) {
                Text(text)
                    .textSelection(.enabled)
                if let quote = nonempty(sourceQuote), sourceQuoteIsValid(quote) {
                    sourceButton(quote)
                }
            }
        }
    }

    private func sourceButton(_ quote: String) -> some View {
        Button {
            onViewSource(quote)
        } label: {
            Label("View in Transcript", systemImage: "text.magnifyingglass")
                .font(.caption)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    private func summarySection<Content: View>(
        title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
