import Foundation

@main
struct NoteTitleHorizontalScrollFieldTests {
    static func main() throws {
        try testDetailTitleUsesHorizontallyScrollableField()
        try testHorizontallyScrollableTitleFieldDefinesSingleLineAppKitWrapper()
        try testTitleFieldClampsSelectionAfterProgrammaticTextShrink()
        try testTitleFieldDelegatesHorizontalWheelAndMapsVerticalWheel()
        try testTitleFieldUsesSafeResizeAndSharedScrollBounds()
        try testTitleFieldClampsClipOriginAfterDocumentWidthChanges()
        try testOpeningANoteShowsItsTitleWithoutSavingIt()
        print("NoteTitleHorizontalScrollFieldTests passed")
    }

    private static func testDetailTitleUsesHorizontallyScrollableField() throws {
        let source = try String(contentsOfFile: "Sources/NoteBrowserView.swift", encoding: .utf8)
        let header = sourceBlock(
            in: source,
            from: "private var noteHeader: some View",
            to: "\n            if let suggestedCalendarTitle"
        )

        precondition(header.contains("HorizontallyScrollableTitleField("))
        // The same date the list names an untitled note by.
        precondition(header.contains("placeholder: NoteTitleResolver.dateTitle(for: item),"))
        precondition(header.contains("text: $titleDraft"))
        precondition(!header.contains("TextField(\n                item.timestamp.formatted(date: .long, time: .shortened),\n                text: $titleDraft"))
        precondition(header.contains(".onChange(of: titleDraft)"))
        precondition(header.contains("appState.updateHistoryItemTitle(id: item.id, title: newValue)"))
        precondition(header.contains(".overrideCursor(.iBeam)"))
    }

    // #361: opening a note whose saved title has line breaks shows it on one
    // line without saving it (the title field clock stays). The field is set
    // only through `applyOutsideTitle`, which marks the text as not typed, so
    // `.onChange(of: titleDraft)` skips the save for it.
    private static func testOpeningANoteShowsItsTitleWithoutSavingIt() throws {
        let source = try String(contentsOfFile: "Sources/NoteBrowserView.swift", encoding: .utf8)
        let apply = sourceBlock(in: source, from: "private func applyOutsideTitle(_ title: String)", to: "\n    }")
        precondition(apply.contains("appliedOutsideTitle = title"))
        precondition(apply.contains("titleDraft = title"))
        let header = sourceBlock(in: source, from: "private var noteHeader: some View", to: "\n            if let suggestedCalendarTitle")
        precondition(header.contains("applyOutsideTitle(NoteTitleResolver.titleDraft(for: item.customTitle))"))
        precondition(header.contains("if newValue == appliedOutsideTitle {\n                    appliedOutsideTitle = nil\n                    return\n                }"))
        // The skip returns before any save is scheduled.
        let onChange = sourceBlock(in: header, from: ".onChange(of: titleDraft)", to: ".onAppear")
        let skip = try requireRange(onChange.range(of: "if newValue == appliedOutsideTitle {"))
        let timer = try requireRange(onChange.range(of: "Timer("))
        let save = try requireRange(onChange.range(of: "appState.updateHistoryItemTitle"))
        precondition(skip.upperBound < timer.lowerBound && skip.upperBound < save.lowerBound,
                     "opening a note must return before a save is scheduled")
        let assignments = (source.components(separatedBy: "titleDraft = ").count - 1)
            - (source.components(separatedBy: "var titleDraft = ").count - 1)
        precondition(assignments == 1, "the title field's text is set only in applyOutsideTitle")
    }

    private static func testHorizontallyScrollableTitleFieldDefinesSingleLineAppKitWrapper() throws {
        let source = try String(contentsOfFile: "Sources/NoteBrowserView.swift", encoding: .utf8)
        let component = sourceBlock(
            in: source,
            from: "private struct HorizontallyScrollableTitleField: NSViewRepresentable",
            to: "\n// MARK: - Note List Row"
        )

        precondition(component.contains("@Binding var text: String"))
        precondition(component.contains("func makeNSView(context: Context) -> TitleHorizontalScrollView"))
        precondition(component.contains("TitleSingleLineTextView"))
        precondition(component.contains("textView.textContainer?.maximumNumberOfLines = 1"))
        precondition(component.contains("textView.textContainer?.widthTracksTextView = false"))
        precondition(component.contains("textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude"))
        precondition(component.contains("parent.text = textView.string"))
        precondition(component.contains("override func scrollWheel(with event: NSEvent)"))
        precondition(component.contains("scrollHorizontally(by: delta)"))
        precondition(!component.contains("appState.updateHistoryItemTitle"))
    }

    private static func testTitleFieldClampsSelectionAfterProgrammaticTextShrink() throws {
        let source = try String(contentsOfFile: "Sources/NoteBrowserView.swift", encoding: .utf8)
        let updateNSView = sourceBlock(
            in: source,
            from: "func updateNSView(_ scrollView: TitleHorizontalScrollView, context: Context)",
            to: "\n        textView.updateDocumentWidth(minimumWidth: scrollView.contentView.bounds.width)"
        )

        precondition(updateNSView.contains("clampedRanges"))
        precondition(updateNSView.contains("textView.selectedRanges = clampedRanges"))
    }

    private static func testTitleFieldDelegatesHorizontalWheelAndMapsVerticalWheel() throws {
        let source = try String(contentsOfFile: "Sources/NoteBrowserView.swift", encoding: .utf8)
        let scrollView = sourceBlock(
            in: source,
            from: "private final class TitleHorizontalScrollView: NSScrollView",
            to: "\nprivate final class TitleSingleLineTextView: NSTextView"
        )

        precondition(scrollView.contains("if abs(event.scrollingDeltaX) > 0.01"))
        precondition(scrollView.contains("super.scrollWheel(with: event)"))
        precondition(scrollView.contains("let delta = -normalizedScrollDelta(event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas)"))
        precondition(scrollView.contains("scrollHorizontally(by: delta)"))
        precondition(!scrollView.contains("scrollHorizontally(by: event.scrollingDeltaX)"))
        precondition(!scrollView.contains("scrollHorizontally(by: event.scrollingDeltaY)"))
    }

    private static func testTitleFieldUsesSafeResizeAndSharedScrollBounds() throws {
        let source = try String(contentsOfFile: "Sources/NoteBrowserView.swift", encoding: .utf8)
        let scrollView = sourceBlock(
            in: source,
            from: "private final class TitleHorizontalScrollView: NSScrollView",
            to: "\nprivate final class TitleSingleLineTextView: NSTextView"
        )

        precondition(scrollView.contains("override func resizeSubviews(withOldSize oldSize: NSSize)"))
        precondition(!scrollView.contains("override func layout()"))
        precondition(scrollView.contains("private var maximumScrollX: CGFloat"))
        precondition(scrollView.contains("let maximumX = maximumScrollX"))
        precondition(scrollView.contains("private func normalizedScrollDelta(_ delta: CGFloat, precise: Bool) -> CGFloat"))
    }

    private static func testTitleFieldClampsClipOriginAfterDocumentWidthChanges() throws {
        let source = try String(contentsOfFile: "Sources/NoteBrowserView.swift", encoding: .utf8)
        let textView = sourceBlock(
            in: source,
            from: "func updateDocumentWidth(minimumWidth: CGFloat)",
            to: "\n    private static func singleLine(_ string: String) -> String"
        )
        let scrollView = sourceBlock(
            in: source,
            from: "private final class TitleHorizontalScrollView: NSScrollView",
            to: "\nprivate final class TitleSingleLineTextView: NSTextView"
        )

        precondition(textView.contains("clampHorizontalScrollOffset()"))
        precondition(scrollView.contains("func clampHorizontalScrollOffset()"))
        precondition(scrollView.contains("reflectScrolledClipView(contentView)"))
    }

    private static func sourceBlock(in source: String, from startMarker: String, to endMarker: String) -> String {
        guard let start = source.range(of: startMarker),
              let end = source.range(of: endMarker, range: start.upperBound..<source.endIndex) else {
            preconditionFailure("Expected source block from \(startMarker) to \(endMarker)")
        }
        return String(source[start.lowerBound..<end.lowerBound])
    }
}

private struct MissingSourceRange: Error {}

private func requireRange(_ range: Range<String.Index>?) throws -> Range<String.Index> {
    guard let range else { throw MissingSourceRange() }
    return range
}
