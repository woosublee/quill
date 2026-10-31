#if os(macOS)
import AppKit
import SwiftUI

// The Mac's pointer override: a small AppKit view behind a SwiftUI view that
// sets the cursor over it. The note toolbar puts one behind each button, as
// the Mac toolbar did before it was shared (#698): without a view of its own
// there, a button floating over the transcript's text view showed no help
// tag. The Mac app uses the same helper for its other cursor overrides.

public final class CursorNSView: NSView {
    public var cursor: NSCursor

    /// Cursor overrides currently in a window. Text views underneath one
    /// (such as the transcript under the floating toolbar) defer to it.
    private static let liveViews = NSHashTable<CursorNSView>.weakObjects()

    public init(cursor: NSCursor) {
        self.cursor = cursor
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            Self.liveViews.remove(self)
        } else {
            Self.liveViews.add(self)
        }
    }

    /// The override cursor for a point in window coordinates, if one covers it.
    public static func cursor(atWindowPoint point: NSPoint, in window: NSWindow?) -> NSCursor? {
        guard let window else { return nil }
        for view in liveViews.allObjects
        where view.window === window && !view.isHiddenOrHasHiddenAncestor {
            if view.convert(view.bounds, to: nil).contains(point) {
                return view.cursor
            }
        }
        return nil
    }

    public override func layout() {
        super.layout()
        updateTrackingAreas()
        window?.invalidateCursorRects(for: self)
    }

    public override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        guard !bounds.isEmpty else { return }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .cursorUpdate, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        ))
    }

    public override func cursorUpdate(with event: NSEvent) {
        cursor.set()
    }
}

struct CursorView: NSViewRepresentable {
    var cursor: NSCursor
    func makeNSView(context: Context) -> CursorNSView { CursorNSView(cursor: cursor) }
    func updateNSView(_ nsView: CursorNSView, context: Context) { nsView.cursor = cursor }
}

extension View {
    public func overrideCursor(_ cursor: NSCursor) -> some View {
        self.background(CursorView(cursor: cursor))
    }
}
#endif
