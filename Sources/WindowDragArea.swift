import AppKit
import SwiftUI

/// What a double-click on a window's title bar does, from the user's choice
/// in System Settings › Desktop & Dock › "Double-click a window's title bar to".
enum TitleBarDoubleClickAction: Equatable {
    case zoom
    case minimize
    case none

    /// `AppleActionOnDoubleClick` holds "Maximize", "Minimize", "None", or
    /// "Fill". Older systems only set the `AppleMiniaturizeOnDoubleClick`
    /// flag. Anything unknown or missing zooms, the system default.
    static func resolve(
        actionOnDoubleClick: String?,
        miniaturizeOnDoubleClick: Bool
    ) -> TitleBarDoubleClickAction {
        switch actionOnDoubleClick {
        case "Minimize":
            return .minimize
        case "None":
            return .none
        case "Maximize", "Fill":
            return .zoom
        case nil:
            // Only older systems without the newer setting use this flag.
            return miniaturizeOnDoubleClick ? .minimize : .zoom
        default:
            return .zoom
        }
    }

    static var current: TitleBarDoubleClickAction {
        let defaults = UserDefaults.standard
        return resolve(
            actionOnDoubleClick: defaults.string(forKey: "AppleActionOnDoubleClick"),
            miniaturizeOnDoubleClick: defaults.bool(forKey: "AppleMiniaturizeOnDoubleClick")
        )
    }
}

/// Empty title bar space that drags the window, for windows whose content
/// extends under a transparent title bar. A double-click does what the
/// system title bar would.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard event.clickCount == 2 else {
                window?.performDrag(with: event)
                return
            }
            switch TitleBarDoubleClickAction.current {
            case .zoom:
                window?.performZoom(nil)
            case .minimize:
                window?.performMiniaturize(nil)
            case .none:
                break
            }
        }
    }
}

/// Reports how much taller the window's title bar is than the 52-point
/// unified title bar the headers were laid out for. macOS 27 draws it 66
/// points tall, and content in that band drags or zooms the window instead
/// of taking clicks, so headers move down by the difference.
struct TitleBarExtraHeightReader: NSViewRepresentable {
    static let designedHeight: CGFloat = 52
    @Binding var extraHeight: CGFloat

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onChange = { extraHeight = $0 }
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.onChange = { extraHeight = $0 }
    }

    final class ProbeView: NSView {
        var onChange: ((CGFloat) -> Void)?
        private var observers: [NSObjectProtocol] = []
        private var reported: CGFloat?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            // Full screen hides the title bar; resizing can change it.
            observers = [
                NSWindow.didResizeNotification,
                NSWindow.didEnterFullScreenNotification,
                NSWindow.didExitFullScreenNotification
            ].map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    self?.report()
                }
            }
            report()
        }

        private func report() {
            guard let window else { return }
            let titleBarHeight = window.frame.height - window.contentLayoutRect.height
            let extra = max(0, titleBarHeight - TitleBarExtraHeightReader.designedHeight)
            guard extra != reported else { return }
            reported = extra
            // Not during a SwiftUI update.
            DispatchQueue.main.async { [weak self] in self?.onChange?(extra) }
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}

private struct TitleBarExtraHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// See `TitleBarExtraHeightReader`.
    var titleBarExtraHeight: CGFloat {
        get { self[TitleBarExtraHeightKey.self] }
        set { self[TitleBarExtraHeightKey.self] = newValue }
    }
}
