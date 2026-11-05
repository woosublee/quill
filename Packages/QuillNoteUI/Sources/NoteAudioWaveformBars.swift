import QuillAudioLevelCore
import SwiftUI

/// The bars of a note's audio waveform, on the Mac and on iOS. A bar keeps its
/// width at every size, so a wider card shows more bars rather than wider ones.
/// With no levels yet (still loading, or the audio isn't here), the bars are
/// flat. Seeking, focus, and accessibility stay with each app's player.
public struct NoteAudioWaveformBars: View {
    /// From `AudioWaveformHeights.sliceLevels(from:)`.
    let levels: [Double]
    let progress: Double
    let playedColor: Color
    let unplayedColor: Color

    @Environment(\.displayScale) private var displayScale
    @State private var heights = HeightCache()

    private static let flatHeight: CGFloat = 0.15

    public init(levels: [Double], progress: Double = 0, playedColor: Color, unplayedColor: Color) {
        self.levels = levels
        self.progress = progress
        self.playedColor = playedColor
        self.unplayedColor = unplayedColor
    }

    public var body: some View {
        Canvas { context, size in
            let layout = AudioWaveformHeights.fittedLayout(width: size.width)
            guard layout.barCount > 0 else { return }
            let bars = heights.heights(levels: levels, barCount: layout.barCount)
            let playedCount = Int(Double(layout.barCount) * min(1, max(0, progress)))
            let scale = max(displayScale, 1)
            for index in 0..<layout.barCount {
                let height = size.height * (bars.isEmpty ? Self.flatHeight : CGFloat(bars[index]))
                // On whole pixels, so the gaps stay even.
                let x = (CGFloat(index) * (layout.barWidth + layout.gap) * scale).rounded() / scale
                let rect = CGRect(x: x, y: (size.height - height) / 2, width: layout.barWidth, height: height)
                context.fill(
                    Path(roundedRect: rect, cornerRadius: layout.barWidth / 2),
                    with: .color(index < playedCount ? playedColor : unplayedColor)
                )
            }
        }
    }
}

/// Playback redraws the bars several times a second, and only the played part
/// changes, so the heights are worked out once per recording and bar count.
@MainActor
private final class HeightCache {
    private var levels: [Double] = []
    private var barCount = 0
    private var cached: [Float] = []

    func heights(levels: [Double], barCount: Int) -> [Float] {
        if barCount != self.barCount || levels != self.levels {
            self.levels = levels
            self.barCount = barCount
            cached = AudioWaveformHeights.heights(fromSliceLevels: levels, barCount: barCount)
        }
        return cached
    }
}
