import SwiftUI

/// Shows an edited summary next to a newly made one, before anything is
/// saved (#262). Choosing a side stretches it across and pushes the other
/// out; with Reduce Motion the other side just fades.
struct MeetingSummaryComparisonView: View {
    let current: MeetingSummaryEnvelope
    let candidate: MeetingSummaryEnvelope
    let sourceQuoteIsValid: (String) -> Bool
    let onKeepCurrent: () -> Void
    let onUseNew: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var choice: Choice?

    private enum Choice {
        case keepCurrent
        case useNew
    }

    private static let cardGap: CGFloat = 16
    private static let sideMargin: CGFloat = 28
    /// Matches the Summary tab's width, so the chosen side lands where the
    /// summary then shows.
    private static let summaryWidth: CGFloat = 760
    private static let summaryMargin: CGFloat = 40
    private static let pushDuration = 0.55

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The bar folds away while the chosen side stretches, so the
            // summary lands where the Summary tab then shows it.
            if choice == nil {
                choiceBar
                    .padding(.horizontal, Self.sideMargin)
                    .padding(.top, 14)
                    .transition(.opacity)
            }
            GeometryReader { geometry in
                ScrollView {
                    cards(in: geometry.size.width)
                        .padding(.top, choice == nil ? 16 : 14)
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
            Text("Choose the summary to use")
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 8)
            Button("Keep Current Summary") { choose(.keepCurrent) }
            Button("Use New Summary") { choose(.useNew) }
                .keyboardShortcut(.defaultAction)
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
        let summary = min(
            max(totalWidth - Self.summaryMargin * 2, 0),
            Self.summaryWidth
        )
        let pushes = choice != nil && !reduceMotion
        let currentWidth: CGFloat
        let candidateWidth: CGFloat
        switch (pushes ? choice : nil) {
        case .keepCurrent:
            currentWidth = summary
            candidateWidth = 0
        case .useNew:
            currentWidth = 0
            candidateWidth = summary
        case nil:
            currentWidth = half
            candidateWidth = half
        }
        return HStack(alignment: .top, spacing: pushes ? 0 : Self.cardGap) {
            card(
                current,
                kind: .current,
                contentWidth: choice == .keepCurrent ? currentWidth : half
            )
            // A pushed-out side keeps its width and slides out of its edge.
            .frame(width: currentWidth, alignment: .trailing)
            .clipped()
            .opacity(choice == .useNew ? 0 : 1)

            card(
                candidate,
                kind: .candidate,
                contentWidth: choice == .useNew ? candidateWidth : half
            )
            .frame(width: candidateWidth, alignment: .leading)
            .clipped()
            .opacity(choice == .keepCurrent ? 0 : 1)
        }
        .frame(maxWidth: .infinity)
    }

    private enum CardKind {
        case current
        case candidate
    }

    private func card(
        _ envelope: MeetingSummaryEnvelope,
        kind: CardKind,
        contentWidth: CGFloat
    ) -> some View {
        let isChosen = (kind == .current && choice == .keepCurrent)
            || (kind == .candidate && choice == .useNew)
        return VStack(alignment: .leading, spacing: 22) {
            if isChosen {
                if kind == .current, envelope.isEdited {
                    editedMarker
                }
            } else {
                cardHeader(envelope, kind: kind)
                    .transition(.opacity)
            }
            MeetingSummaryReadOnlyContent(
                content: envelope.content,
                sourceQuoteIsValid: sourceQuoteIsValid,
                matchesEditor: isChosen
            )
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

    private func cardHeader(_ envelope: MeetingSummaryEnvelope, kind: CardKind) -> some View {
        HStack(spacing: 8) {
            Text(kind == .current ? "Current Summary" : "New Summary")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 1)
                .background(
                    kind == .current
                        ? Color.primary.opacity(0.07)
                        : Color.accentColor.opacity(0.14),
                    in: Capsule()
                )
            if kind == .current, envelope.isEdited {
                Text("Edited")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
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
            case .keepCurrent: onKeepCurrent()
            case .useNew: onUseNew()
            }
        }
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
