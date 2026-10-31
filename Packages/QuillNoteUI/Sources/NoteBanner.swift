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
    public let perform: () -> Void

    public init(title: String, perform: @escaping () -> Void) {
        self.title = title
        self.perform = perform
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
        onDismiss: (() -> Void)? = nil
    ) {
        self.systemImage = systemImage
        self.tint = tint
        self.title = title
        self.detail = detail
        self.strings = strings
        self.action = action
        self.expansion = expansion
        self.onDismiss = onDismiss
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
            if let action {
                NoteBannerActionButton(action: action)
            }
            if let onDismiss {
                NoteBannerDismissButton(label: strings.dismiss, action: onDismiss)
            }
        }
        .padding(.leading, QuillSpacing.space10)
        .padding(.trailing, onDismiss == nil ? QuillSpacing.space10 : QuillSpacing.space6)
        // 7 is off the spacing scale (#736); it stays a literal for now.
        .padding(.vertical, onDismiss == nil ? 7 : QuillSpacing.space6)
        .noteBannerBackground()
        .help(Text(verbatim: detail))
    }

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
        onDismiss != nil || expansion != nil || (action != nil && !stacksAction)
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
        Button(action: action.perform) {
            Text(verbatim: action.title)
                #if os(macOS)
                // 11.5 pt has no token yet (#736).
                .font(.system(size: 11.5, weight: .medium))
                #else
                .font(.system(.caption, weight: .medium))
                #endif
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, QuillSpacing.space9)
                .padding(.vertical, QuillSpacing.space3)
                .background(NoteBannerButtonSurface())
                .contentShape(RoundedRectangle(cornerRadius: QuillRadius.radius6))
                #if os(iOS)
                .frame(minHeight: QuillControlSize.touchMin)
                .contentShape(Rectangle())
                #endif
        }
        .buttonStyle(.plain)
        .fixedSize()
    }
}

/// A banner or issue row button's chrome.
public struct NoteBannerButtonSurface: View {
    @Environment(\.colorScheme) private var colorScheme

    public init() {}

    public var body: some View {
        RoundedRectangle(cornerRadius: QuillRadius.radius6)
            .fill(Color.primary.opacity(0.08))
            .overlay(
                RoundedRectangle(cornerRadius: QuillRadius.radius6)
                    .strokeBorder(QuillColor.hairline.color(for: colorScheme), lineWidth: 1)
            )
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
