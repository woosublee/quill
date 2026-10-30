import SwiftUI
import QuillDesignTokens

// How a note's running work looks, the same on the Mac and the iPhone
// (#697). The look is the Mac's: a spinner and a title, alone in the middle
// of a note with no text yet, or in a capsule over the text the work will
// replace. When the work reports progress, a bar and its percentage follow.

public struct NoteWorkStatusView: View {
    public enum Style: Equatable, Sendable {
        /// Alone in the middle of a note with nothing to show yet.
        case centered
        /// A capsule over text the work will replace.
        case capsule
    }

    let presentation: NoteWorkStatus.Presentation
    let style: Style

    public init(_ presentation: NoteWorkStatus.Presentation, style: Style) {
        self.presentation = presentation
        self.style = style
    }

    public var body: some View {
        Group {
            switch style {
            case .centered: centered
            case .capsule: capsule
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabel))
        .modifier(NoteWorkStatusAccessibilityValue(value: presentation.percentText))
    }

    private var centered: some View {
        VStack(spacing: QuillSpacing.space14) {
            if presentation.indicator == .spinner {
                ProgressView()
                    .controlSize(.regular)
            }
            Text(verbatim: presentation.title)
                .font(QuillTypeStyle.emptyTitle.font)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if presentation.progress != nil {
                progressRow
            }
            detail
        }
    }

    private var capsule: some View {
        // A capsule while the status is one line; with a bar or a reason
        // under it, the glass notice's rounded rectangle keeps its ends round.
        // One shape whose radius changes, so the view keeps its identity
        // when the first progress arrives. A radius past half the height
        // draws a capsule.
        // Circular corners at the clamped radius draw exactly `Capsule()`.
        let isOneLine = presentation.progress == nil && presentation.detail == nil
        return capsuleContent.modifier(NoteWorkStatusChrome(
            shape: RoundedRectangle(
                cornerRadius: isOneLine ? Self.capsuleRadius : QuillRadius.radius18,
                style: isOneLine ? .circular : .continuous
            )
        ))
    }

    /// `radius-capsule` in tokens.json.
    private static let capsuleRadius: CGFloat = 999

    private var capsuleContent: some View {
        VStack(spacing: QuillSpacing.space6) {
            HStack(spacing: QuillSpacing.space8) {
                if presentation.indicator == .spinner {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(verbatim: presentation.title)
                    .font(QuillTypeStyle.statusTitle.font)
                    .foregroundStyle(.secondary)
            }
            if presentation.progress != nil {
                progressRow
            }
            detail
        }
        .padding(.horizontal, QuillSpacing.space14)
        .padding(.vertical, QuillSpacing.space9)
    }

    @ViewBuilder
    private var progressRow: some View {
        if let progress = presentation.progress, let percentText = presentation.percentText {
            HStack(spacing: QuillSpacing.space8) {
                ProgressView(value: progress.fraction)
                    .progressViewStyle(.linear)
                    .frame(width: QuillControlSize.statusProgress)
                Text(verbatim: percentText)
                    .font(QuillTypeStyle.statusPercent.font)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let detail = presentation.detail {
            Text(verbatim: detail)
                .font(QuillTypeStyle.statusDetail.font)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                // A long reason wraps under the bar's width instead of
                // stretching the capsule across the note.
                .frame(maxWidth: QuillControlSize.statusProgress)
        }
    }

    private var accessibilityLabel: String {
        [presentation.title, presentation.detail].compactMap { $0 }.joined(separator: ", ")
    }
}

/// The capsule's glass: material, a hairline edge, and its shadow.
struct NoteWorkStatusChrome<S: InsettableShape>: ViewModifier {
    let shape: S

    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background(.regularMaterial, in: shape)
            .overlay(shape.strokeBorder(QuillColor.hairlineStrong.color(for: colorScheme)))
            .quillShadow(.status)
    }
}

/// The capsule over the note's text, on a light wash of the note's own
/// background so the text underneath stays readable. It takes the pointer
/// and taps, so the text under it can't be edited while the work runs.
public struct NoteWorkStatusOverlay: View {
    /// Where the capsule sits on the wash.
    public enum Placement: Equatable, Sendable {
        /// In the middle, a little above centre: over a note body that fills
        /// its own scroll view (the Mac).
        case center
        /// At the top: over text inside a longer scrolling page, where the
        /// middle can be off screen (the iPhone note detail).
        case top

        var alignment: Alignment { self == .top ? .top : .center }
        /// The capsule sits a little above centre, or just below the top.
        var capsuleInset: (edge: Edge.Set, length: CGFloat) {
            self == .top ? (.top, QuillSpacing.space8) : (.bottom, QuillSpacing.space60)
        }
    }

    let presentation: NoteWorkStatus.Presentation
    let placement: Placement

    public init(_ presentation: NoteWorkStatus.Presentation, placement: Placement = .center) {
        self.presentation = presentation
        self.placement = placement
    }

    public var body: some View {
        ZStack(alignment: placement.alignment) {
            Rectangle()
                .fill(Self.noteBackground.opacity(QuillOpacity.statusWash))
            Self.capsule(presentation, placement: placement)
        }
        .transition(.opacity)
        .allowsHitTesting(true)
    }

    static func capsule(_ presentation: NoteWorkStatus.Presentation, placement: Placement) -> some View {
        NoteWorkStatusView(presentation, style: .capsule)
            .padding(placement.capsuleInset.edge, placement.capsuleInset.length)
    }

    /// The note body's background: the text background on the Mac, the
    /// system background on iOS.
    private static var noteBackground: Color {
        #if os(macOS)
        Color(nsColor: .textBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }
}

extension View {
    /// Covers this view with `NoteWorkStatusOverlay` while `presentation` is
    /// set. With `.top` the view grows to at least the capsule's height, so
    /// a capsule over one short line doesn't spill onto what follows; the
    /// content keeps its identity when the cover comes and goes.
    public func noteWorkStatusOverlay(
        _ presentation: NoteWorkStatus.Presentation?,
        placement: NoteWorkStatusOverlay.Placement = .center
    ) -> some View {
        ZStack(alignment: .topLeading) {
            self
            if let presentation, placement == .top {
                NoteWorkStatusOverlay.capsule(presentation, placement: placement).hidden()
            }
        }
        .overlay {
            if let presentation {
                NoteWorkStatusOverlay(presentation, placement: placement)
            }
        }
    }
}

/// The small spinner beside a tab's name while work runs on that tab's
/// content out of view. Its help tag and VoiceOver label are the status title.
public struct NoteWorkStatusIndicator: View {
    let presentation: NoteWorkStatus.Presentation

    public init(_ presentation: NoteWorkStatus.Presentation) {
        self.presentation = presentation
    }

    public var body: some View {
        if presentation.indicator == .spinner {
            ProgressView()
                .controlSize(.mini)
                #if os(macOS)
                .help(presentation.title)
                #endif
                .accessibilityLabel(Text(verbatim: presentation.title))
                .modifier(NoteWorkStatusAccessibilityValue(value: presentation.percentText))
        }
    }
}

/// Adds the percentage as the VoiceOver value only when there is one.
struct NoteWorkStatusAccessibilityValue: ViewModifier {
    let value: String?

    func body(content: Content) -> some View {
        if let value {
            content.accessibilityValue(Text(verbatim: value))
        } else {
            content
        }
    }
}
