#if os(macOS)
import AppKit
import SwiftUI

// The Mac's pointer override: a small AppKit view behind a SwiftUI view that
// sets the cursor over it. The note toolbar puts one behind each button, as
// the Mac toolbar did before it was shared (#698): without a view of its own
// there, a button floating over the transcript's text view showed no help
// tag. The Mac app uses the same helper for its other cursor overrides.

/// Which override cursor covers a point, for text views underneath one
/// (such as the transcript under the floating toolbar).
public enum QuillCursorOverride {
    /// The override cursor for a point in window coordinates, if one covers it.
    @MainActor
    public static func cursor(atWindowPoint point: NSPoint, in window: NSWindow?) -> NSCursor? {
        CursorNSView.cursor(atWindowPoint: point, in: window)
    }
}

extension View {
    public func overrideCursor(_ cursor: NSCursor) -> some View {
        self.background(CursorView(cursor: cursor))
    }
}

struct CursorView: NSViewRepresentable {
    var cursor: NSCursor
    /// Whether text views underneath look this view up. A view inside an
    /// override that already covers it (a toolbar button) needn't be.
    var isInLookup = true

    func makeNSView(context: Context) -> CursorNSView {
        CursorNSView(cursor: cursor, isInLookup: isInLookup)
    }

    func updateNSView(_ nsView: CursorNSView, context: Context) { nsView.cursor = cursor }
}

final class CursorNSView: NSView {
    var cursor: NSCursor
    private let isInLookup: Bool
    private var trackedBounds: NSRect?

    /// Cursor overrides currently in a window that text views look up.
    private static let liveViews = NSHashTable<CursorNSView>.weakObjects()

    init(cursor: NSCursor, isInLookup: Bool = true) {
        self.cursor = cursor
        self.isInLookup = isInLookup
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard isInLookup else { return }
        if window == nil {
            Self.liveViews.remove(self)
        } else {
            Self.liveViews.add(self)
        }
    }

    static func cursor(atWindowPoint point: NSPoint, in window: NSWindow?) -> NSCursor? {
        guard let window else { return nil }
        for view in liveViews.allObjects
        where view.window === window && !view.isHiddenOrHasHiddenAncestor {
            if view.convert(view.bounds, to: nil).contains(point) {
                return view.cursor
            }
        }
        return nil
    }

    override func layout() {
        super.layout()
        // Only when the size changes; AppKit calls updateTrackingAreas itself
        // when the view moves.
        guard trackedBounds != bounds else { return }
        trackedBounds = bounds
        updateTrackingAreas()
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }

    override func updateTrackingAreas() {
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

    override func cursorUpdate(with event: NSEvent) {
        cursor.set()
    }
}
#endif
