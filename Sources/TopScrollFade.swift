import SwiftUI

extension View {
    /// Dissolves content scrolled into the top `height` points instead of
    /// cutting it off at the edge. Content at rest should start below it.
    func topScrollFade(height: CGFloat) -> some View {
        mask(
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [.clear, .black],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: height)
                Rectangle()
            }
        )
    }
}
