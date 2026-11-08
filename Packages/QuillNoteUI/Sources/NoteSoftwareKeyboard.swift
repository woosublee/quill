import CoreGraphics
import SwiftUI
#if os(iOS)
import UIKit
#endif

// Whether the on-screen keyboard is up, for the note toolbar's hiding rule
// (2026-11-08 decision t4): the toolbar hides while editing only when the
// keyboard covers the screen's bottom. An iPad with a hardware keyboard
// shows just the shortcut bar, which doesn't count.

public enum NoteSoftwareKeyboard {
    /// A keyboard frame shorter than this is the hardware keyboard's
    /// shortcut bar (about 55 to 75 points), not the on-screen keyboard
    /// (at least about 200 points on every iPhone and iPad).
    public static let minimumHeight: CGFloat = 150

    /// Whether a keyboard ending at `endFrame` is the on-screen keyboard
    /// on a screen of `screenBounds`. A frame moved off the screen is a
    /// hidden keyboard.
    public static func isVisible(endFrame: CGRect, screenBounds: CGRect) -> Bool {
        let visible = endFrame.intersection(screenBounds)
        return !visible.isNull && visible.height >= minimumHeight
    }
}

#if os(iOS)
/// Follows the on-screen keyboard for the whole app, so a note screen made
/// while the keyboard is already up reads it right away. The app touches
/// `shared` at launch to start following.
@MainActor
public final class NoteSoftwareKeyboardMonitor: ObservableObject {
    public static let shared = NoteSoftwareKeyboardMonitor()

    @Published public private(set) var isVisible = false
    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
                self?.update(frame: frame, screen: (note.object as? UIScreen)?.bounds)
            }
        })
        observers.append(center.addObserver(
            forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.isVisible = false }
        })
    }

    private func update(frame: CGRect, screen: CGRect?) {
        // The notification names its screen; otherwise the app's first
        // window scene's.
        let bounds = screen ?? UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.screen.bounds }
            .first
        guard let bounds else {
            isVisible = frame.height >= NoteSoftwareKeyboard.minimumHeight
            return
        }
        isVisible = NoteSoftwareKeyboard.isVisible(endFrame: frame, screenBounds: bounds)
    }
}
#endif
