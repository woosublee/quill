import SwiftUI

/// The wording for one comparison: a summary or a transcript.
struct ComparisonLabels {
    let prompt: LocalizedStringKey
    let keepCurrent: LocalizedStringKey
    let useNew: LocalizedStringKey
    let currentTag: LocalizedStringKey
    let newTag: LocalizedStringKey
    /// A note next to the current side's tag, such as "Edited".
    var currentNote: LocalizedStringKey?
}

/// How the chosen side ends up, so it lands where the tab then shows it.
struct ComparisonLanding {
    /// The chosen side's width for the tab's full width.
    let width: (CGFloat) -> CGFloat
    let topPadding: CGFloat
}

/// Shows the current content next to a newly made one before anything is
/// saved (#262, #457). Choosing a side stretches it across and pushes the
/// other out; with Reduce Motion the other side just fades.
struct SideBySideChoiceView<Side: View, ChosenHeader: View>: View {
    enum Kind {
        case current
        case candidate
    }

    let labels: ComparisonLabels
    let landing: ComparisonLanding
    /// Shown above the chosen current side as it lands, like the tab's own
    /// marker (for example "Edited summary · Revert to Original").
    let chosenCurrentHeader: ChosenHeader
    let side: (Kind, _ isChosen: Bool) -> Side
    let onKeepCurrent: () -> Void
    /// False when the new content couldn't be saved; both sides come back.
    let onUseNew: () -> Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var choice: Choice?

    private enum Choice {
        case keepCurrent
        case useNew
    }

    private static var cardGap: CGFloat { 16 }
    private static var sideMargin: CGFloat { 28 }
    private static var pushDuration: Double { 0.55 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The bar folds away while the chosen side stretches, so the
            // content lands where the tab then shows it.
            if choice == nil {
                choiceBar
                    .padding(.horizontal, Self.sideMargin)
                    .padding(.top, 14)
                    .transition(.opacity)
            }
            GeometryReader { geometry in
                ScrollView {
                    cards(in: geometry.size.width)
                        .padding(.top, choice == nil ? 16 : landing.topPadding)
                        .padding(.bottom, 96)
                }
            }
        }
    }

    /// Built like `QuillStatusBanner`, with the two choices on the right.
    private var choiceBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text(labels.prompt)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 8)
            // Return keeps what is saved; replacing it takes a click.
            Button(labels.keepCurrent) { choose(.keepCurrent) }
                .keyboardShortcut(.defaultAction)
            Button(labels.useNew) { choose(.useNew) }
        }
        .font(.system(size: 12))
        .controlSize(.small)
        .disabled(choice != nil)
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .quillBannerBackground()
    }

    private func cards(in totalWidth: CGFloat) -> some View {
        let available = max(totalWidth - Self.sideMargin * 2, 0)
        let half = max((available - Self.cardGap) / 2, 0)
        let landed = landing.width(totalWidth)
        let pushes = choice != nil && !reduceMotion
        let currentWidth: CGFloat
        let candidateWidth: CGFloat
        switch (pushes ? choice : nil) {
        case .keepCurrent:
            currentWidth = landed
            candidateWidth = 0
        case .useNew:
            currentWidth = 0
            candidateWidth = landed
        case nil:
            currentWidth = half
            candidateWidth = half
        }
        return HStack(alignment: .top, spacing: pushes ? 0 : Self.cardGap) {
            card(
                kind: .current,
                contentWidth: choice == .keepCurrent ? currentWidth : half
            )
            // A pushed-out side keeps its width and slides out of its edge.
            .frame(width: currentWidth, alignment: .trailing)
            .clipped()
            .opacity(choice == .useNew ? 0 : 1)

            card(
                kind: .candidate,
                contentWidth: choice == .useNew ? candidateWidth : half
            )
            .frame(width: candidateWidth, alignment: .leading)
            .clipped()
            .opacity(choice == .keepCurrent ? 0 : 1)
        }
        .frame(maxWidth: .infinity)
    }

    private func card(kind: Kind, contentWidth: CGFloat) -> some View {
        let isChosen = (kind == .current && choice == .keepCurrent)
            || (kind == .candidate && choice == .useNew)
        return VStack(alignment: .leading, spacing: 22) {
            if isChosen {
                if kind == .current {
                    chosenCurrentHeader
                }
            } else {
                cardHeader(kind: kind)
                    .transition(.opacity)
            }
            side(kind, isChosen)
        }
        .padding(isChosen ? 0 : 16)
        .frame(width: max(contentWidth, 0), alignment: .leading)
        .background {
            if !isChosen {
                RoundedRectangle(cornerRadius: 10)
                    .fill(kind == .current
                          ? Color.primary.opacity(0.035)
                          : Color.clear)
            }
        }
        .overlay {
            if !isChosen {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        kind == .current
                            ? Color.primary.opacity(0.1)
                            : Color.accentColor.opacity(0.55),
                        lineWidth: kind == .current ? 0.5 : 1.5
                    )
            }
        }
    }

    private func cardHeader(kind: Kind) -> some View {
        HStack(spacing: 8) {
            Text(kind == .current ? labels.currentTag : labels.newTag)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 1)
                .background(
                    kind == .current
                        ? Color.primary.opacity(0.07)
                        : Color.accentColor.opacity(0.14),
                    in: Capsule()
                )
            if kind == .current, let note = labels.currentNote {
                Text(note)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func choose(_ newChoice: Choice) {
        guard choice == nil else { return }
        let duration = reduceMotion ? 0.2 : Self.pushDuration
        let animation: Animation = reduceMotion
            ? .easeOut(duration: duration)
            : .timingCurve(0.2, 0.8, 0.2, 1, duration: duration)
        withAnimation(animation) {
            choice = newChoice
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            switch newChoice {
            case .keepCurrent:
                onKeepCurrent()
            case .useNew:
                if !onUseNew() {
                    withAnimation(animation) { choice = nil }
                }
            }
        }
    }
}

/// An edited summary next to a newly made one (#262).
struct MeetingSummaryComparisonView: View {
    let current: MeetingSummaryEnvelope
    let candidate: MeetingSummaryEnvelope
    let sourceQuoteIsValid: (String) -> Bool
    let onKeepCurrent: () -> Void
    let onUseNew: () -> Bool

    /// Matches the Summary tab's width, so the chosen side lands where the
    /// summary then shows.
    private static let summaryWidth: CGFloat = 760
    private static let summaryMargin: CGFloat = 40

    var body: some View {
        SideBySideChoiceView(
            labels: ComparisonLabels(
                prompt: "Choose the summary to use",
                keepCurrent: "Keep Current Summary",
                useNew: "Use New Summary",
                currentTag: "Current Summary",
                newTag: "New Summary",
                currentNote: current.isEdited ? "Edited" : nil
            ),
            landing: ComparisonLanding(
                width: { total in
                    min(max(total - Self.summaryMargin * 2, 0), Self.summaryWidth)
                },
                topPadding: 14
            ),
            chosenCurrentHeader: Group {
                if current.isEdited { editedMarker }
            },
            side: { kind, isChosen in
                MeetingSummaryReadOnlyContent(
                    content: kind == .current ? current.content : candidate.content,
                    sourceQuoteIsValid: sourceQuoteIsValid,
                    matchesEditor: isChosen
                )
            },
            onKeepCurrent: onKeepCurrent,
            onUseNew: onUseNew
        )
    }

    /// Looks like the Summary tab's marker, which takes its place next.
    private var editedMarker: some View {
        HStack(spacing: 6) {
            Image(systemName: "pencil")
                .font(.system(size: 11, weight: .medium))
            Text("Edited summary")
            Text(verbatim: "·")
                .foregroundStyle(.tertiary)
            Text("Revert to Original")
                .foregroundStyle(Color.accentColor)
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
}

/// The current transcript next to a retranscribed one (#457). The chosen
/// side lands like the Transcript tab's text: full width, 40 pt insets.
struct TranscriptComparisonView: View {
    let current: String
    let candidate: String
    let onKeepCurrent: () -> Void
    let onUseNew: () -> Bool

    var body: some View {
        SideBySideChoiceView(
            labels: ComparisonLabels(
                prompt: "Choose the transcript to use",
                keepCurrent: "Keep Current Transcript",
                useNew: "Use New Transcript",
                currentTag: "Current Transcript",
                newTag: "New Transcript"
            ),
            landing: ComparisonLanding(
                width: { total in max(total - 80, 0) },
                topPadding: 20
            ),
            chosenCurrentHeader: EmptyView(),
            side: { kind, _ in
                Text(kind == .current ? current : candidate)
                    .font(.system(size: 15))
                    .lineSpacing(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            },
            onKeepCurrent: onKeepCurrent,
            onUseNew: onUseNew
        )
    }
}

/// A summary's sections as plain text, for comparing. Laid out like
/// `MeetingSummaryView`, so the chosen side turns into the Summary tab
/// without moving; `matchesEditor` adds the rows only the editor has.
private struct MeetingSummaryReadOnlyContent: View {
    let content: MeetingSummaryContent
    let sourceQuoteIsValid: (String) -> Bool
    let matchesEditor: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            section("Overview") {
                Text(content.overview.text)
            }
            pointSection("Key Points", content.keyPoints)
            pointSection("Decisions", content.decisions)
            section("Action Items") {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(content.actionItems) { item in
                        actionRow(item)
                    }
                    trailingRow(isEmpty: content.actionItems.isEmpty, newRowTitle: "New Action Item", isAction: true)
                }
            }
            pointSection("Open Questions", content.openQuestions)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func pointSection(
        _ title: LocalizedStringKey,
        _ points: [MeetingSummaryPoint]
    ) -> some View {
        section(title) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(points) { point in
                    HStack(alignment: .top, spacing: 10) {
                        Circle()
                            .fill(Color.secondary.opacity(0.45))
                            .frame(width: 4, height: 4)
                            .padding(.top, 6)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(point.text)
                            sourceLine(point.sourceQuote)
                        }
                    }
                }
                trailingRow(isEmpty: points.isEmpty, newRowTitle: "New Item", isAction: false)
            }
        }
    }

    private func actionRow(_ item: MeetingSummaryActionItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle(item.task, isOn: .constant(item.isCompleted))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.task)
                    .strikethrough(item.isCompleted)
                    .foregroundStyle(item.isCompleted ? .secondary : .primary)
                Text(metadata(item))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                sourceLine(item.sourceQuote)
            }
        }
    }

    /// "None" for an empty section while comparing; the editor's dimmed
    /// new-row line once this side is chosen.
    @ViewBuilder
    private func trailingRow(
        isEmpty: Bool,
        newRowTitle: LocalizedStringKey,
        isAction: Bool
    ) -> some View {
        if matchesEditor {
            HStack(spacing: 10) {
                if isAction {
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(Color.secondary.opacity(0.45), lineWidth: 1)
                        .frame(width: 13, height: 13)
                } else {
                    Circle()
                        .fill(Color.secondary.opacity(0.45))
                        .frame(width: 4, height: 4)
                }
                Text(newRowTitle)
            }
            .foregroundStyle(.tertiary)
        } else if isEmpty {
            Text("None")
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func sourceLine(_ quote: String?) -> some View {
        if let quote = quote?.trimmingCharacters(in: .whitespacesAndNewlines),
           !quote.isEmpty,
           sourceQuoteIsValid(quote) {
            Label("View in Transcript", systemImage: "text.magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func section<Content: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func metadata(_ item: MeetingSummaryActionItem) -> String {
        let owner = item.owner.flatMap { $0.isEmpty ? nil : $0 }
            ?? localizedCatalogString("Owner needs review")
        let dueDate = item.dueDate.flatMap { $0.isEmpty ? nil : $0 }
            ?? localizedCatalogString("Due date needs review")
        return "\(owner) · \(dueDate)"
    }
}
