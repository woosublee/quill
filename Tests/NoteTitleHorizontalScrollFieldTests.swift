import Foundation

@main
struct NoteTitleHorizontalScrollFieldTests {
    static func main() throws {
        try testDetailTitleUsesHorizontallyScrollableField()
        try testHorizontallyScrollableTitleFieldDefinesSingleLineAppKitWrapper()
        try testTitleFieldClampsSelectionAfterProgrammaticTextShrink()
        try testTitleFieldHandlesHorizontalWheelDeltaBeforeVerticalFallback()
        try testTitleFieldClampsClipOriginAfterDocumentWidthChanges()
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
        precondition(header.contains("placeholder: item.timestamp.formatted(date: .long, time: .shortened),"))
        precondition(header.contains("text: $titleDraft"))
        precondition(!header.contains("TextField(\n                item.timestamp.formatted(date: .long, time: .shortened),\n                text: $titleDraft"))
        precondition(header.contains(".onChange(of: titleDraft)"))
        precondition(header.contains("appState.updateHistoryItemTitle(id: item.id, title: newValue)"))
        precondition(header.contains(".overrideCursor(.iBeam)"))
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
        precondition(component.contains("scrollHorizontally(by: event.scrollingDeltaY)"))
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

    private static func testTitleFieldHandlesHorizontalWheelDeltaBeforeVerticalFallback() throws {
        let source = try String(contentsOfFile: "Sources/NoteBrowserView.swift", encoding: .utf8)
        let scrollView = sourceBlock(
            in: source,
            from: "private final class TitleHorizontalScrollView: NSScrollView",
            to: "\nprivate final class TitleSingleLineTextView: NSTextView"
        )

        precondition(scrollView.contains("scrollHorizontally(by: event.scrollingDeltaX)"))
        precondition(scrollView.contains("scrollHorizontally(by: event.scrollingDeltaY)"))
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
