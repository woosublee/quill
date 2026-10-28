import SwiftUI

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

    public init(
        firstAction: @escaping (NoteToolbarFirstAction) -> String,
        progress: String,
        copy: String,
        copyUnavailable: String,
        save: String,
        createSummary: String,
        delete: String
    ) {
        self.firstAction = firstAction
        self.progress = progress
        self.copy = copy
        self.copyUnavailable = copyUnavailable
        self.save = save
        self.createSummary = createSummary
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
    /// The capsule's height (the Mac's; the iPhone's buttons are its touch
    /// targets).
    #if os(macOS)
    public static let height: CGFloat = 48
    static let buttonSize: CGFloat = 36
    static let saveSymbol = "square.and.arrow.down"
    #else
    public static let height: CGFloat = 56
    static let buttonSize: CGFloat = 44
    static let saveSymbol = "square.and.arrow.up"
    #endif

    let state: NoteToolbarState
    let labels: NoteToolbarLabels
    let actions: NoteToolbarActions
    /// The copy button shows a checkmark for a moment after copying.
    let showsCopyConfirmation: Bool
    /// The capsule's fill under Reduce Transparency.
    let opaqueBackground: Color

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init(
        state: NoteToolbarState,
        labels: NoteToolbarLabels,
        actions: NoteToolbarActions,
        showsCopyConfirmation: Bool = false,
        opaqueBackground: Color
    ) {
        self.state = state
        self.labels = labels
        self.actions = actions
        self.showsCopyConfirmation = showsCopyConfirmation
        self.opaqueBackground = opaqueBackground
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
                    label: labels.firstAction(action)
                ) {
                    icon(action.isCancel ? "xmark.circle" : "arrow.clockwise", color: firstSlotColor(action, isEnabled: isEnabled))
                }
                divider
            }

            NoteToolbarIconButton(
                action: actions.copy,
                isEnabled: state.isCopyEnabled,
                label: state.isCopyEnabled ? labels.copy : labels.copyUnavailable
            ) {
                icon(
                    showsCopyConfirmation ? "checkmark" : "doc.on.doc",
                    color: showsCopyConfirmation ? .accentColor : (state.isCopyEnabled ? .primary : .secondary)
                )
            }

            NoteToolbarIconButton(action: actions.save, isEnabled: state.isSaveEnabled, label: labels.save) {
                icon(Self.saveSymbol, color: state.isSaveEnabled ? .primary : .secondary)
            }

            if case .button(let isEnabled) = state.createSummary {
                NoteToolbarIconButton(
                    action: actions.createSummary,
                    isEnabled: isEnabled,
                    label: labels.createSummary
                ) {
                    icon("sparkles", color: isEnabled ? .primary : .secondary)
                }
            }

            divider

            NoteToolbarIconButton(action: actions.delete, isEnabled: state.isDeleteEnabled, label: labels.delete) {
                icon("trash", color: Color.red.opacity(0.8))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: Self.height)
        .background { background }
        .overlay(Capsule().strokeBorder(strokeColor, lineWidth: 0.6))
        .compositingGroup()
        .shadow(color: .black.opacity(0.085), radius: 14, x: 0, y: 4)
        .shadow(color: .white.opacity(0.05), radius: 4, x: 0, y: -1)
        .contentShape(Capsule())
    }

    /// Cancel is plain; the transcript tab's actions are orange (dimmed
    /// when off); the summary tab's ↻ turns gray when it can't run.
    private func firstSlotColor(_ action: NoteToolbarFirstAction, isEnabled: Bool) -> Color {
        if action.isCancel { return .primary }
        if action == .runSummary, !isEnabled { return .secondary }
        return .orange
    }

    private func icon(_ systemName: String, color: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .medium))
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

    private var strokeColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.10) : Color.primary.opacity(0.10)
    }
}

/// One slot. A disabled button keeps its place, dimmed.
struct NoteToolbarIconButton<Label: View>: View {
    let action: () -> Void
    let isEnabled: Bool
    let label: String
    @ViewBuilder let content: () -> Label

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            content()
                .frame(width: NoteFloatingToolbar.buttonSize, height: NoteFloatingToolbar.buttonSize)
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
        .onHover { hovering in
            isHovered = hovering && isEnabled
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
                            ? Color.primary.opacity(0.12)
                            : (isHovered ? hoverFillColor : Color.clear)
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

    private var hoverFillColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.primary.opacity(0.07)
    }

    private var hoverStrokeColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.16) : Color.primary.opacity(0.12)
    }
}
