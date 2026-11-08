import SwiftUI
import QuillDesignTokens

// The Keep/Use comparison both apps show after a retranscription or a
// summary regeneration (#262, #457; the owner's 2026-11-08 decisions c1 and
// c5). Each app keeps its own choice bar and what happens on a choice; the
// sides' layout, copy keys, and card look are shared here.

/// One side of a comparison.
public enum NoteComparisonSide: Hashable, CaseIterable, Sendable {
    case current
    case candidate
}

/// How the two sides lay out, from the window's width class (decision c1).
/// A regular or wide window puts the two cards side by side, as the Mac
/// does; a compact one (a phone, a narrow iPad window) shows one side at a
/// time under a segmented picker. The window decides, not the note column,
/// so the Mac, whose window is always wide, keeps its cards side by side
/// down to its narrowest note column.
public enum NoteComparisonLayout: Equatable, Sendable {
    case sideBySide
    case segmented

    public init(windowClass: QuillWidthClass) {
        self = windowClass == .compact ? .segmented : .sideBySide
    }

    /// The side a segmented comparison shows first: the new one (c5).
    public static let firstShownSide = NoteComparisonSide.candidate
}

/// The comparison's copy keys. Each app translates them with its own
/// String Catalog.
public struct NoteComparisonCopy: Equatable, Sendable {
    public let prompt: String
    public let keepCurrent: String
    public let useNew: String
    public let currentTag: String
    public let newTag: String

    public static let transcript = Self(
        prompt: "Choose the transcript to use",
        keepCurrent: "Keep Current Transcript",
        useNew: "Use New Transcript",
        currentTag: "Current Transcript",
        newTag: "New Transcript"
    )

    public static let summary = Self(
        prompt: "Choose the summary to use",
        keepCurrent: "Keep Current Summary",
        useNew: "Use New Summary",
        currentTag: "Current Summary",
        newTag: "New Summary"
    )

    /// Beside the current summary's tag when it was edited.
    public static let editedNote = "Edited"

    public func tag(_ side: NoteComparisonSide) -> String {
        side == .current ? currentTag : newTag
    }

    public var allKeys: [String] { [prompt, keepCurrent, useNew, currentTag, newTag] }
}

/// The cards' look: the current side on a faint fill with a hairline edge,
/// the new side clear with an accent edge, each under a tag pill.
public enum NoteComparisonCardStyle {
    public static let padding = QuillSpacing.space16
    public static let cornerRadius = QuillRadius.radius10
    public static let gap = QuillSpacing.space16

    public static func fillOpacity(_ side: NoteComparisonSide) -> Double {
        side == .current ? 0.035 : 0
    }

    public static func strokeOpacity(_ side: NoteComparisonSide) -> Double {
        side == .current ? 0.1 : 0.55
    }

    public static func strokeWidth(_ side: NoteComparisonSide) -> CGFloat {
        side == .current ? 0.5 : 1.5
    }

    public static func tagFillOpacity(_ side: NoteComparisonSide) -> Double {
        side == .current ? 0.07 : 0.14
    }

    static func base(_ side: NoteComparisonSide) -> Color {
        side == .current ? .primary : .accentColor
    }
}

extension View {
    /// Draws this content as one comparison card.
    public func noteComparisonCard(_ side: NoteComparisonSide) -> some View {
        padding(NoteComparisonCardStyle.padding)
            .background(
                RoundedRectangle(cornerRadius: NoteComparisonCardStyle.cornerRadius)
                    .fill(Color.primary.opacity(NoteComparisonCardStyle.fillOpacity(side)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: NoteComparisonCardStyle.cornerRadius)
                    .strokeBorder(
                        NoteComparisonCardStyle.base(side).opacity(NoteComparisonCardStyle.strokeOpacity(side)),
                        lineWidth: NoteComparisonCardStyle.strokeWidth(side)
                    )
            )
    }
}

/// A card's tag pill ("Current Transcript", "New Summary").
public struct NoteComparisonTag: View {
    let side: NoteComparisonSide
    let title: String

    public init(_ side: NoteComparisonSide, title: String) {
        self.side = side
        self.title = title
    }

    public var body: some View {
        Text(verbatim: title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, QuillSpacing.space8)
            .padding(.vertical, 1)
            .background(
                NoteComparisonCardStyle.base(side).opacity(NoteComparisonCardStyle.tagFillOpacity(side)),
                in: Capsule()
            )
    }
}

/// The two sides laid out by `NoteComparisonLayout`: two cards side by
/// side, or a segmented picker over one card. `card` draws one side's whole
/// card (its tag, content, and `noteComparisonCard`).
public struct NoteComparisonSides<Card: View>: View {
    let layout: NoteComparisonLayout
    let currentTag: String
    let newTag: String
    @Binding var shownSide: NoteComparisonSide
    let card: (NoteComparisonSide) -> Card

    /// - Parameters:
    ///   - currentTag, newTag: the localized tags, for the segmented picker.
    public init(
        layout: NoteComparisonLayout,
        currentTag: String,
        newTag: String,
        shownSide: Binding<NoteComparisonSide>,
        @ViewBuilder card: @escaping (NoteComparisonSide) -> Card
    ) {
        self.layout = layout
        self.currentTag = currentTag
        self.newTag = newTag
        _shownSide = shownSide
        self.card = card
    }

    public var body: some View {
        switch layout {
        case .sideBySide:
            // The current side first, as the buttons and the Mac's cards.
            HStack(alignment: .top, spacing: NoteComparisonCardStyle.gap) {
                card(.current).frame(maxWidth: .infinity, alignment: .topLeading)
                card(.candidate).frame(maxWidth: .infinity, alignment: .topLeading)
            }
        case .segmented:
            VStack(alignment: .leading, spacing: QuillSpacing.space12) {
                Picker(selection: $shownSide) {
                    Text(verbatim: currentTag).tag(NoteComparisonSide.current)
                    Text(verbatim: newTag).tag(NoteComparisonSide.candidate)
                } label: {
                    EmptyView()
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                card(shownSide)
            }
        }
    }
}

private struct NoteWindowWidthClassKey: EnvironmentKey {
    static let defaultValue = QuillWidthClass.compact
}

extension EnvironmentValues {
    /// The width class of the window (scene) the view is in, set by the
    /// app's root view. Views inside the note read it where the rule is the
    /// window's, such as `NoteComparisonLayout`.
    public var noteWindowWidthClass: QuillWidthClass {
        get { self[NoteWindowWidthClassKey.self] }
        set { self[NoteWindowWidthClassKey.self] = newValue }
    }
}
