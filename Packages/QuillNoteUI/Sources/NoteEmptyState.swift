import QuillDesignTokens
import SwiftUI

/// An empty state, the same on the Mac, the iPhone, and the iPad (#697 e1):
/// an ultralight symbol inside a light disc, a title, and an optional
/// explanation, all from tokens. Spacing is `space-12` for a standard
/// state and `space-14` for the hero and quiet ones, as the Mac drew them. On iOS the disc, symbol, and text grow
/// with Dynamic Type. Each app passes its localized strings and decides
/// which state shows.
public struct NoteEmptyState: View {
    /// How much the state says.
    public enum Style: Sendable {
        /// No notes at all: the large dashed disc and a larger title.
        case hero
        /// No selection, no search results: the disc, a title, a detail.
        case standard
        /// An empty transcript: the disc and one quiet line.
        case quiet
    }

    /// The disc's edge.
    public enum Edge: Sendable {
        case none
        case solid
        case dashed
    }

    let systemImage: String
    let title: String
    let detail: String?
    let style: Style
    let edge: Edge

    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric private var disc: CGFloat
    @ScaledMetric private var glyph: CGFloat

    public init(systemImage: String, title: String, detail: String? = nil, style: Style, edge: Edge) {
        self.systemImage = systemImage
        self.title = title
        self.detail = detail
        self.style = style
        self.edge = edge
        let isHero = style == .hero
        // The disc and symbol grow with the title beside them.
        let textStyle: Font.TextStyle = isHero ? .title3 : .subheadline
        _disc = ScaledMetric(wrappedValue: isHero ? QuillControlSize.emptyDiscLarge : QuillControlSize.emptyDisc, relativeTo: textStyle)
        _glyph = ScaledMetric(wrappedValue: isHero ? QuillControlSize.emptyGlyphLarge : QuillControlSize.emptyGlyph, relativeTo: textStyle)
    }

    public var body: some View {
        VStack(spacing: style == .standard ? QuillSpacing.space12 : QuillSpacing.space14) {
            ZStack {
                Circle()
                    .fill(QuillColor.fillEmptyDisc.color(for: colorScheme))
                    .overlay { edgeStroke }
                Image(systemName: systemImage)
                    .font(.system(size: glyph, weight: .ultraLight))
                    .foregroundStyle(.tertiary)
            }
            .frame(width: disc, height: disc)
            .accessibilityHidden(true)
            Text(title)
                .quillTextStyle(titleStyle)
                .foregroundStyle(style == .quiet ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                .multilineTextAlignment(.center)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .quillTextStyle(style == .hero ? .emptyHeroDetail : .emptyDetail)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: style == .standard ? QuillControlSize.emptyDetailWidth : nil)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var titleStyle: QuillTypeStyle {
        switch style {
        case .hero: return .emptyHeroTitle
        case .standard: return .emptyTitle
        case .quiet: return .emptyQuietTitle
        }
    }

    @ViewBuilder
    private var edgeStroke: some View {
        switch edge {
        case .none:
            EmptyView()
        case .solid:
            Circle().stroke(QuillColor.hairlineStrong.color(for: colorScheme), lineWidth: 1)
        case .dashed:
            Circle().stroke(
                QuillColor.hairlineStrong.color(for: colorScheme),
                style: StrokeStyle(lineWidth: 1, dash: [4])
            )
        }
    }
}

/// The empty states' copy keys, shared so both apps say the same thing
/// (#697 e2, e3, e6). Each app translates them with its own String Catalog.
public enum NoteEmptyStateCopy {
    public static let noRecordingsTitle = "No Recordings"
    /// The list's one line beside a detail column that shows the full state
    /// (a wide window, e4).
    public static let noRecordingsListLine = "No recordings yet"
    public static let noSearchResults = "No Search Results"
    public static let noMatchingNotes = "No Matching Notes"
    /// "No notes match “%@”. Try another word, or clear the search."
    public static let noMatchingNotesDetailFormat = "No notes match “%@”. Try another word, or clear the search."
    public static let selectNoteTitle = "Select a Note"
    public static let selectNoteDetail = "Select a recording from the list to view its transcript"
    /// A finished transcript that is empty or only whitespace (e5, e6, e7).
    public static let noContent = "No content"

    /// The "No Recordings" explanation. The Mac also mentions its shortcut.
    public static func noRecordingsDetail(mentionsShortcut: Bool) -> String {
        mentionsShortcut
            ? "Start your first recording with the Record button or your shortcut.\nYour transcript will appear here."
            : "Start your first recording with the Record button.\nYour transcript will appear here."
    }

    /// Every key, for catalog checks.
    public static let allKeys: [String] = [
        noRecordingsTitle, noRecordingsListLine, noSearchResults, noMatchingNotes,
        noMatchingNotesDetailFormat, selectNoteTitle, selectNoteDetail, noContent,
        noRecordingsDetail(mentionsShortcut: true), noRecordingsDetail(mentionsShortcut: false),
    ]
}
