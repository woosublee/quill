import CoreGraphics

/// The note browser's headers were laid out for a 52-point unified title
/// bar. macOS 27 draws it 66 points tall, and content in the extra band drags
/// or zooms the window instead of taking clicks, so the headers move down by
/// the difference.
enum TitleBarLayout {
    static let designedHeight: CGFloat = 52

    static func extraHeight(titleBarHeight: CGFloat) -> CGFloat {
        max(0, titleBarHeight - designedHeight)
    }
}
