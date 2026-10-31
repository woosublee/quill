import SwiftUI
import QuillDesignTokens

// The note's floating toolbar, the same on the Mac and the iPhone (#690,
// #697). It draws `NoteToolbarState` and calls back; the app holds the
// note's state and runs the work.

/// The text the toolbar shows: help tags on the Mac, accessibility labels
/// on both. Each app passes its own localized strings.
public struct NoteToolbarLabels {
    public var firstAction: (NoteToolbarFirstAction) -> String
    public var progress: String
    public var copy: String
    public var copyUnavailable: String
    public var save: String
    public var createSummary: String
    public var delete: String
    /// Optional accessibility hints, for VoiceOver.
    public var firstActionHint: (NoteToolbarFirstAction) -> String?
    public var copyHint: String?
    public var saveHint: String?
    public var createSummaryHint: String?
    public var deleteHint: String?

    public init(
        firstAction: @escaping (NoteToolbarFirstAction) -> String,
        progress: String,
        copy: String,
        copyUnavailable: String,
        save: String,
        createSummary: String,
        delete: String,
        firstActionHint: @escaping (NoteToolbarFirstAction) -> String? = { _ in nil },
        copyHint: String? = nil,
        saveHint: String? = nil,
        createSummaryHint: String? = nil,
        deleteHint: String? = nil
    ) {
        self.firstAction = firstAction
        self.progress = progress
        self.copy = copy
        self.copyUnavailable = copyUnavailable
        self.save = save
        self.createSummary = createSummary
        self.delete = delete
        self.firstActionHint = firstActionHint
        self.copyHint = copyHint
        self.saveHint = saveHint
        self.createSummaryHint = createSummaryHint
        self.deleteHint = deleteHint
    }
}

/// The action colors the toolbar draws with. Each app passes its own, so
/// both keep their look until #697 settles one set (#623).
public struct NoteToolbarColors {
    /// The transcript tab's actions and the summary tab's ↻.
    public var retry: Color
    /// The copy checkmark.
    public var copied: Color
    public var delete: Color

    public init(retry: Color = QuillColor.issueWarning, copied: Color = .accentColor, delete: Color = Color.red.opacity(0.8)) {
        self.retry = retry
        self.copied = copied
        self.delete = delete
    }
}

public struct NoteToolbarActions {
    public var firstAction: (NoteToolbarFirstAction) -> Void
    public var copy: () -> Void
    public var save: () -> Void
    public var createSummary: () -> Void
    public var delete: () -> Void

    public init(
        firstAction: @escaping (NoteToolbarFirstAction) -> Void,
        copy: @escaping () -> Void,
        save: @escaping () -> Void,
        createSummary: @escaping () -> Void,
        delete: @escaping () -> Void
    ) {
        self.firstAction = firstAction
        self.copy = copy
        self.save = save
        self.createSummary = createSummary
        self.delete = delete
    }
}

public struct NoteFloatingToolbar: View {
    /// The capsule's height on both platforms.
    public static let height = QuillControlSize.noteToolbar
    /// 36 on the Mac; on the iPhone, the minimum touch target, growing with Dynamic Type.
    static let buttonSize = QuillControlSize.noteToolbarButton
    #if os(macOS)
    static let saveSymbol = "square.and.arrow.down"
    /// Pointer density on the Mac.
    static let iconFont = Font.system(size: 13, weight: .medium)
    #else
    static let saveSymbol = "square.and.arrow.up"
    /// Follows Dynamic Type: 13 pt leaves the 44 pt touch target looking empty.
    static let iconFont = Font.body
    #endif

    let state: NoteToolbarState
    let labels: NoteToolbarLabels
    let actions: NoteToolbarActions
    /// The copy button shows a checkmark for a moment after copying.
    let showsCopyConfirmation: Bool
    /// The capsule's fill under Reduce Transparency.
    let opaqueBackground: Color
    let colors: NoteToolbarColors

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init(
        state: NoteToolbarState,
        labels: NoteToolbarLabels,
        actions: NoteToolbarActions,
        showsCopyConfirmation: Bool = false,
        opaqueBackground: Color,
        colors: NoteToolbarColors = NoteToolbarColors()
    ) {
        self.state = state
        self.labels = labels
        self.actions = actions
        self.showsCopyConfirmation = showsCopyConfirmation
        self.opaqueBackground = opaqueBackground
        self.colors = colors
    }

    public var body: some View {
        HStack(spacing: 2) {
            switch state.firstSlot {
            case .none:
                EmptyView()
            case .progress:
                NoteToolbarIconButton(action: {}, isEnabled: false, label: labels.progress) {
                    spinner
                }
                divider
            case .button(let action, let isEnabled):
                NoteToolbarIconButton(
                    action: { actions.firstAction(action) },
                    isEnabled: isEnabled,
                    label: labels.firstAction(action),
                    hint: labels.firstActionHint(action)
                ) {
                    icon(firstSlotSymbol(action), color: firstSlotColor(action, isEnabled: isEnabled))
                }
                divider
            }

            NoteToolbarIconButton(
                action: actions.copy,
                isEnabled: state.isCopyEnabled,
                label: state.isCopyEnabled ? labels.copy : labels.copyUnavailable,
                hint: labels.copyHint
            ) {
                icon(
                    showsCopyConfirmation ? "checkmark" : "doc.on.doc",
                    color: showsCopyConfirmation ? colors.copied : (state.isCopyEnabled ? .primary : .secondary)
                )
            }

            NoteToolbarIconButton(
                action: actions.save, isEnabled: state.isSaveEnabled, label: labels.save, hint: labels.saveHint
            ) {
                icon(Self.saveSymbol, color: state.isSaveEnabled ? .primary : .secondary)
            }

            if case .button(let isEnabled) = state.createSummary {
                NoteToolbarIconButton(
                    action: actions.createSummary,
                    isEnabled: isEnabled,
                    label: labels.createSummary,
                    hint: labels.createSummaryHint
                ) {
                    icon("sparkles", color: isEnabled ? .primary : .secondary)
                }
            }

            divider

            NoteToolbarIconButton(
                action: actions.delete, isEnabled: state.isDeleteEnabled, label: labels.delete, hint: labels.deleteHint
            ) {
                icon("trash", color: colors.delete)
            }
        }
        .padding(.horizontal, QuillSpacing.space8)
        .frame(height: Self.height)
        .background { background }
        .overlay(Capsule().strokeBorder(QuillColor.strokeGlass.color(for: colorScheme), lineWidth: 0.6))
        .compositingGroup()
        .quillShadow(.glass)
        .shadow(color: .white.opacity(0.05), radius: 4, x: 0, y: -1)
        .contentShape(Capsule())
    }

    private func firstSlotSymbol(_ action: NoteToolbarFirstAction) -> String {
        if action.isCancel { return "xmark.circle" }
        if action == .openModelSetup { return "gearshape.fill" }
        return "arrow.clockwise"
    }

    /// Cancel and model setup are plain; the transcript tab's actions are
    /// the retry color (dimmed when off); the summary tab's ↻ turns gray
    /// when it can't run.
    private func firstSlotColor(_ action: NoteToolbarFirstAction, isEnabled: Bool) -> Color {
        if action.isCancel || action == .openModelSetup { return .primary }
        if action == .runSummary, !isEnabled { return .secondary }
        return colors.retry
    }

    private func icon(_ systemName: String, color: Color) -> some View {
        Image(systemName: systemName)
            .font(Self.iconFont)
            .foregroundStyle(color)
    }

    private var spinner: some View {
        ProgressView()
            .controlSize(.mini)
            .frame(width: 14, height: 14)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 0.5, height: 18)
            .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var background: some View {
        // Opaque under Reduce Transparency.
        if reduceTransparency {
            Capsule().fill(opaqueBackground)
        } else {
            #if compiler(>=6.2)
            if #available(macOS 26.0, iOS 26.0, *) {
                Color.clear.glassEffect(.regular, in: Capsule())
            } else {
                Capsule().fill(.ultraThinMaterial)
            }
            #else
            Capsule().fill(.ultraThinMaterial)
            #endif
        }
    }
}

/// One slot. A disabled button keeps its place, dimmed.
struct NoteToolbarIconButton<Label: View>: View {
    let action: () -> Void
    let isEnabled: Bool
    let label: String
    var hint: String?
    @ViewBuilder let content: () -> Label

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            content()
                #if os(macOS)
                .frame(width: NoteFloatingToolbar.buttonSize, height: NoteFloatingToolbar.buttonSize)
                #else
                .frame(minWidth: NoteFloatingToolbar.buttonSize, minHeight: NoteFloatingToolbar.buttonSize)
                #endif
                .opacity(isEnabled ? 1 : 0.35)
                .contentShape(Circle())
        }
        // A button turned off under the pointer drops its hover look.
        .buttonStyle(NoteToolbarButtonStyle(isHovered: isHovered && isEnabled))
        .disabled(!isEnabled)
        #if os(macOS)
        .help(label)
        #endif
        .accessibilityLabel(Text(label))
        .modifier(NoteToolbarHint(hint: hint))
        #if os(macOS)
        // As before #698: the pointer can't fall through to the transcript
        // between the buttons.
        .contentShape(Circle())
        .allowsHitTesting(true)
        #endif
        .onHover { hovering in
            isHovered = hovering && isEnabled
        }
        #if os(macOS)
        // Each button needs an AppKit view of its own for its help tag to
        // show over the transcript's text view, as before #698. The
        // toolbar-wide override already answers the text view's lookup.
        .background(CursorView(cursor: .arrow, isInLookup: false))
        #endif
    }
}

/// Adds a VoiceOver hint only when the app gives one.
struct NoteToolbarHint: ViewModifier {
    let hint: String?

    func body(content: Content) -> some View {
        if let hint {
            content.accessibilityHint(Text(hint))
        } else {
            content
        }
    }
}

struct NoteToolbarButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Circle()
                    .fill(
                        configuration.isPressed
                            ? QuillColor.fillPressed.color(for: colorScheme)
                            : (isHovered ? QuillColor.fillToolbarHover.color(for: colorScheme) : Color.clear)
                    )
            )
            .overlay(
                Circle()
                    .strokeBorder(hoverStrokeColor.opacity(isHovered ? 1 : 0), lineWidth: 0.5)
            )
            .contentShape(Circle())
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .animation(.easeInOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeInOut(duration: 0.12), value: isHovered)
    }

    private var hoverStrokeColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.16) : Color.primary.opacity(0.12)
    }
}
