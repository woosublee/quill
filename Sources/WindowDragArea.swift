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
