import SwiftUI
import QuillDesignTokens

// The one-line notice above a note's content, the same on the Mac and the
// iPhone (#744). It is drawn only from the design tokens; each app passes
// its own localized strings and the tint. The platforms differ only where
// they must: the iPhone has no tooltips, so a detail that doesn't fit drops
// to a second line instead, and its buttons get a 44 pt touch area.

/// The text the banner's own controls show. Each app passes its own
/// localized strings.
public struct NoteBannerStrings: Sendable {
    public var showLess: String
    public var showAllNotices: String
    public var dismiss: String

    public init(showLess: String, showAllNotices: String, dismiss: String) {
        self.showLess = showLess
        self.showAllNotices = showAllNotices
        self.dismiss = dismiss
    }
}

/// Lets the first banner of a group reveal or hide the rest.
public struct NoteBannerExpansion {
    public let hiddenCount: Int
    public let isExpanded: Bool
    public let toggle: () -> Void

    public init(hiddenCount: Int, isExpanded: Bool, toggle: @escaping () -> Void) {
        self.hiddenCount = hiddenCount
        self.isExpanded = isExpanded
        self.toggle = toggle
    }
}

/// A button beside the banner's text (the iPhone's "Show Summary", for
/// example).
public struct NoteBannerAction {
    public let title: String
    /// Drawn filled with the accent color, like the Mac's default button
    /// (the comparison bar's "Keep Current"). Plain by default.
    public let isProminent: Bool
    public let perform: () -> Void

    public init(title: String, isProminent: Bool = false, perform: @escaping () -> Void) {
        self.title = title
        self.isProminent = isProminent
        self.perform = perform
    }
}

/// What the banner's info button shows: lines of text (the issue's body
/// and suggestion), then label and value rows (the diagnostic details),
/// like the Mac issue banner's popover.
public struct NoteBannerDetails {
    public struct Row: Hashable {
        public let label: String
        public let value: String

        public init(label: String, value: String) {
            self.label = label
            self.value = value
        }
    }

    /// The info button's spoken name ("Issue Details").
    public let label: String
    public let lines: [String]
    public let rows: [Row]

    public init(label: String, lines: [String], rows: [Row] = []) {
        self.label = label
        self.lines = lines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        self.rows = rows.filter {
            !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    public var isEmpty: Bool { lines.isEmpty && rows.isEmpty }

    /// The details a banner shows behind its info button: nil when there is
    /// nothing to show, so no button appears.
    public static func shown(_ details: NoteBannerDetails?) -> NoteBannerDetails? {
        guard let details, !details.isEmpty else { return nil }
        return details
    }
}

public struct NoteBanner: View {
    let systemImage: String
    let tint: Color
    let title: String
    let detail: String
    let strings: NoteBannerStrings
    var action: NoteBannerAction?
    var expansion: NoteBannerExpansion?
    var onDismiss: (() -> Void)?
    var details: NoteBannerDetails?

    #if os(iOS)
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #endif

    public init(
        systemImage: String,
        tint: Color,
        title: String,
        detail: String,
        strings: NoteBannerStrings,
        action: NoteBannerAction? = nil,
        expansion: NoteBannerExpansion? = nil,
        onDismiss: (() -> Void)? = nil,
        details: NoteBannerDetails? = nil
    ) {
        self.systemImage = systemImage
        self.tint = tint
        self.title = title
        self.detail = detail
        self.strings = strings
        self.action = action
        self.expansion = expansion
        self.onDismiss = onDismiss
        self.details = NoteBannerDetails.shown(details)
    }

    public var body: some View {
        #if os(macOS)
        macBody
        #else
        touchBody
        #endif
    }

    private var spokenText: String {
        detail.isEmpty ? title : "\(title) \(detail)"
    }

    private var icon: some View {
        Image(systemName: systemImage)
            #if os(macOS)
            // 11 pt has no token yet (#736); it stays a literal for now.
            .font(.system(size: 11, weight: .semibold))
            #else
            .quillTextStyle(.bannerTitle)
            #endif
            .foregroundStyle(tint)
            .accessibilityHidden(true)
    }

    private var detailText: some View {
        Text(detail)
            .quillTextStyle(.callout)
            .foregroundStyle(.secondary)
    }

    // MARK: Mac

    #if os(macOS)
    /// The detail shows beside the title when it fits, and as a tooltip
    /// always.
    private var macBody: some View {
        HStack(spacing: QuillSpacing.space8) {
            icon
            if let expansion {
                titleText
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: spokenText))
                Spacer(minLength: 0)
                NoteBannerExpansionButton(expansion: expansion, strings: strings)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: QuillSpacing.space8) {
                        titleText
                        detailText
                            .lineLimit(1)
                            .fixedSize()
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 0) {
                        titleText
                        Spacer(minLength: 0)
                    }
                }
                // Title and detail read as one element; the close button
                // stays a separate control.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: spokenText))
            }
            if let details {
                NoteBannerDetailsButton(details: details)
            }
            if let action {
                NoteBannerActionButton(action: action)
            }
            if let onDismiss {
                NoteBannerDismissButton(label: strings.dismiss, action: onDismiss)
            }
        }
        .padding(.leading, QuillSpacing.space10)
        .padding(.trailing, hasSmallControl ? QuillSpacing.space6 : QuillSpacing.space10)
        // 7 is off the spacing scale (#736); it stays a literal for now.
        .padding(.vertical, hasSmallControl ? QuillSpacing.space6 : 7)
        .noteBannerBackground()
        .help(Text(verbatim: detail))
    }

    /// A 20 pt control (close or info) sets the banner's height, like the
    /// close button always has.
    private var hasSmallControl: Bool { onDismiss != nil || details != nil }

    private var titleText: some View {
        Text(title)
            .quillTextStyle(.bannerTitle)
            .lineLimit(1)
            .truncationMode(.tail)
    }
    #endif

    // MARK: iPhone and iPad

    #if os(iOS)
    /// The phone has no tooltips, so the detail is never hidden: beside the
    /// title when it fits, below it when not. A group's first banner shows
    /// only its title while folded, like the Mac, and its detail below when
    /// unfolded. Buttons have a 44 pt touch area, so a banner with one is
    /// 44 pt tall. At accessibility text sizes the action drops to its own
    /// line so it doesn't squeeze the title.
    private var touchBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: QuillSpacing.space8) {
                HStack(alignment: .firstTextBaseline, spacing: QuillSpacing.space8) {
                    icon
                    Group {
                        if detail.isEmpty {
                            titleText
                        } else if let expansion {
                            if expansion.isExpanded { stackedText } else { titleText }
                        } else {
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: QuillSpacing.space8) {
                                    titleText
                                    detailText
                                        .lineLimit(1)
                                        .fixedSize()
                                }
                                stackedText
                            }
                        }
                    }
                    .layoutPriority(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Title and detail read as one element; the buttons
                    // stay separate controls.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: spokenText))
                }
                .layoutPriority(1)
                if let details {
                    // Several banners can each have one, so the spoken name says which, like the close button.
                    NoteBannerDetailsButton(details: details, spokenLabel: "\(details.label), \(title)")
                }
                if let action, !stacksAction {
                    NoteBannerActionButton(action: action)
                }
                if let expansion {
                    NoteBannerExpansionButton(expansion: expansion, strings: strings)
                }
                if let onDismiss {
                    NoteBannerDismissButton(label: "\(strings.dismiss), \(title)", action: onDismiss)
                }
            }
            // Without buttons, 7 pt above and below like the Mac (off the
            // spacing scale, #736); with one, its 44 pt touch area sets the
            // height.
            .padding(.vertical, hasRowButtons ? 0 : 7)
            if let action, stacksAction {
                NoteBannerActionButton(action: action)
            }
        }
        .padding(.leading, QuillSpacing.space10)
        .padding(.trailing, onDismiss == nil && expansion == nil ? QuillSpacing.space10 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .noteBannerBackground()
    }

    private var stacksAction: Bool { dynamicTypeSize.isAccessibilitySize }

    private var hasRowButtons: Bool {
        onDismiss != nil || expansion != nil || details != nil || (action != nil && !stacksAction)
    }

    /// No line limit at accessibility text sizes, so nothing is cut off
    /// (the phone has no tooltip to fall back on).
    private var lineLimit: Int? { dynamicTypeSize.isAccessibilitySize ? nil : 2 }

    private var titleText: some View {
        Text(title)
            .quillTextStyle(.bannerTitle)
            .foregroundStyle(.primary)
            .lineLimit(lineLimit)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var stackedText: some View {
        // 1 is off the spacing scale (#736); it stays a literal for now.
        VStack(alignment: .leading, spacing: 1) {
            titleText
            detailText
                .lineLimit(lineLimit)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    #endif
}

/// The "+N" / "Show Less" pill on the first banner of a group.
public struct NoteBannerExpansionButton: View {
    let expansion: NoteBannerExpansion
    let strings: NoteBannerStrings

    public init(expansion: NoteBannerExpansion, strings: NoteBannerStrings) {
        self.expansion = expansion
        self.strings = strings
    }

    public var body: some View {
        Button(action: expansion.toggle) {
            Group {
                if expansion.isExpanded {
                    Text(verbatim: strings.showLess)
                } else {
                    Text(verbatim: "+\(expansion.hiddenCount)")
                }
            }
            #if os(macOS)
            // 11 pt has no token yet (#736).
            .font(.system(size: 11, weight: .semibold))
            #else
            .quillTextStyle(.bannerTitle)
            .lineLimit(1)
            .fixedSize()
            #endif
            .foregroundStyle(.secondary)
            // 7 and the primary 8% fill have no token yet (#736).
            .padding(.horizontal, 7)
            .padding(.vertical, QuillSpacing.space2)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
            #if os(macOS)
            .contentShape(Capsule())
            #else
            // The pill keeps the Mac size; the touch area is 44 pt.
            .frame(minWidth: QuillControlSize.touchMin, minHeight: QuillControlSize.touchMin)
            .contentShape(Rectangle())
            #endif
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .help(expansion.isExpanded ? strings.showLess : strings.showAllNotices)
        #endif
        .accessibilityLabel(expansion.isExpanded ? strings.showLess : strings.showAllNotices)
        #if os(iOS)
        // Folded, it also reads how many notices are hidden.
        .accessibilityValue(Text(verbatim: expansion.isExpanded ? "" : "+\(expansion.hiddenCount)"))
        #endif
    }
}

/// The close button every one-line banner shares.
public struct NoteBannerDismissButton: View {
    let label: String
    let action: () -> Void

    public init(label: String, action: @escaping () -> Void) {
        self.label = label
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                #if os(macOS)
                // 9 pt has no token yet (#736).
                .font(.system(size: 9, weight: .semibold))
                #else
                // Grows with Dynamic Type beside the title.
                .font(.system(.caption2, weight: .semibold))
                #endif
                .foregroundStyle(.secondary)
                #if os(macOS)
                .frame(width: 20, height: 20)
                .contentShape(Circle())
                #else
                // The glyph keeps the Mac size; the touch area is 44 pt.
                .frame(width: QuillControlSize.touchMin, height: QuillControlSize.touchMin)
                .contentShape(Rectangle())
                #endif
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// A small neutral button beside a banner's text: a primary 8% fill (no
/// token yet, #736) and a 1 pt `hairline` edge, on `radius-6`.
public struct NoteBannerActionButton: View {
    let action: NoteBannerAction

    public init(action: NoteBannerAction) {
        self.action = action
    }

    public var body: some View {
        let button = Button(action: action.perform) {
            Text(verbatim: action.title)
                #if os(macOS)
                // 11.5 pt has no token yet (#736).
                .font(.system(size: 11.5, weight: .medium))
                #else
                .font(.system(.caption, weight: .medium))
                #endif
                .lineLimit(1)
                .fixedSize()
                .modifier(NoteBannerProminentLabel(isProminent: action.isProminent))
                .padding(.horizontal, QuillSpacing.space9)
                .padding(.vertical, QuillSpacing.space3)
                .background(NoteBannerButtonSurface(isProminent: action.isProminent))
                .contentShape(RoundedRectangle(cornerRadius: QuillRadius.radius6))
                #if os(iOS)
                .frame(minHeight: QuillControlSize.touchMin)
                .contentShape(Rectangle())
                #endif
        }
        if action.isProminent {
            button.buttonStyle(NoteBannerProminentPressStyle()).fixedSize()
        } else {
            button.buttonStyle(.plain).fixedSize()
        }
    }
}

/// Pressed and disabled looks for the accent-filled action, like the
/// system's prominent button. A plain action keeps `.plain`.
private struct NoteBannerProminentPressStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
    }
}

/// White text on the accent fill. A plain button keeps the text color it
/// inherits, so existing banners draw exactly as before.
private struct NoteBannerProminentLabel: ViewModifier {
    let isProminent: Bool

    func body(content: Content) -> some View {
        if isProminent {
            content.foregroundStyle(Color.white)
        } else {
            content
        }
    }
}

/// The banner's info button and its popover: the lines, then the label
/// and value rows. It is the Mac issue banner's ⓘ (`QuillUserIssueView`
/// draws it too), shared so the iPhone shows the same details (#234). On
/// the iPhone the popover stays a popover instead of a sheet.
public struct NoteBannerDetailsButton: View {
    let details: NoteBannerDetails
    let spokenLabel: String
    @State private var isShowing = false

    public init(details: NoteBannerDetails, spokenLabel: String? = nil) {
        self.details = details
        self.spokenLabel = spokenLabel ?? details.label
    }

    public var body: some View {
        Button {
            isShowing.toggle()
        } label: {
            Image(systemName: "info.circle")
                #if os(macOS)
                // 11 pt has no token yet (#736); it stays a literal for now.
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: QuillControlSize.close, height: QuillControlSize.close)
                .contentShape(Circle())
                #else
                .quillTextStyle(.bannerTitle)
                .foregroundStyle(.secondary)
                .frame(minWidth: QuillControlSize.touchMin, minHeight: QuillControlSize.touchMin)
                .contentShape(Rectangle())
                #endif
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .help(Text(verbatim: details.label))
        #endif
        .accessibilityLabel(Text(verbatim: spokenLabel))
        .popover(isPresented: $isShowing, arrowEdge: .bottom) {
            #if os(iOS)
            if #available(iOS 16.4, *) {
                content.presentationCompactAdaptation(.popover)
            } else {
                content
            }
            #else
            content
            #endif
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: QuillSpacing.space8) {
            ForEach(Array(details.lines.enumerated()), id: \.offset) { _, line in
                Text(verbatim: line)
                    #if os(macOS)
                    // The Mac popover's sizes (12 and 11 pt) have no token yet (#736).
                    .font(.system(size: 12))
                    #else
                    .quillTextStyle(.callout)
                    #endif
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !details.rows.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: QuillSpacing.space12, verticalSpacing: QuillSpacing.space4) {
                    ForEach(Array(details.rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            Text(verbatim: row.label)
                                .foregroundStyle(.secondary)
                            Text(verbatim: row.value)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                #if os(macOS)
                .font(.system(size: 11))
                #else
                .quillTextStyle(.callout)
                #endif
            }
        }
        .padding(QuillSpacing.space12)
        .frame(width: 300, alignment: .leading)
    }
}

/// A banner or issue row button's chrome.
public struct NoteBannerButtonSurface: View {
    var isProminent = false
    @Environment(\.colorScheme) private var colorScheme

    public init(isProminent: Bool = false) {
        self.isProminent = isProminent
    }

    public var body: some View {
        if isProminent {
            RoundedRectangle(cornerRadius: QuillRadius.radius6)
                .fill(Color.accentColor)
        } else {
            RoundedRectangle(cornerRadius: QuillRadius.radius6)
                .fill(Color.primary.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: QuillRadius.radius6)
                        .strokeBorder(QuillColor.hairline.color(for: colorScheme), lineWidth: 1)
                )
        }
    }
}

/// The surface behind every banner and inline issue row: `fill-banner`, a
/// 1 pt `hairline-strong` edge, and `shadow-banner`.
public struct NoteBannerSurface: View {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    public init(cornerRadius: CGFloat = QuillRadius.radius9) {
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(QuillColor.fillBanner.color(for: colorScheme))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(QuillColor.hairlineStrong.color(for: colorScheme), lineWidth: 1)
            )
            .quillShadow(.banner)
    }
}

extension View {
    /// The shared banner look on `radius-9`.
    public func noteBannerBackground() -> some View {
        background(NoteBannerSurface())
    }
}
