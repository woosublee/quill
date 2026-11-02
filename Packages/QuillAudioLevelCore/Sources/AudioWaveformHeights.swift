import Foundation

/// Bar layout and heights for the recording waveform.
public enum AudioWaveformHeights {
    public struct Layout: Sendable {
        public let barCount: Int
        public let barWidth: CGFloat
        public let gap: CGFloat

        public init(barCount: Int, barWidth: CGFloat, gap: CGFloat) {
            self.barCount = barCount
            self.barWidth = barWidth
            self.gap = gap
        }
    }

    public static func layout(width: CGFloat, barCount: Int = 80, preferredGap: CGFloat = 2) -> Layout {
        guard width > 0, barCount > 0 else {
            return Layout(barCount: 0, barWidth: 0, gap: 0)
        }

        let minimumBarWidth: CGFloat = 1
        let maxGap = barCount > 1
            ? max(0, (width - CGFloat(barCount) * minimumBarWidth) / CGFloat(barCount - 1))
            : 0
        let safePreferredGap = max(0, preferredGap)
        let gap = min(safePreferredGap, maxGap)
        let totalGap = gap * CGFloat(max(0, barCount - 1))
        let barWidth = max(0, (width - totalGap) / CGFloat(barCount))

        return Layout(barCount: barCount, barWidth: barWidth, gap: gap)
    }

    /// The shortest bar, drawn for silence.
    public static let floorHeight: Float = 0.04

    /// Bars quieter than this (about -72 dBFS, below a quiet iPhone room)
    /// draw as silence, so a recording of nothing stays flat. Bars fade in
    /// over `silenceFadeDB` above it rather than jumping up.
    static let silenceLevelDB: Double = -72
    static let silenceFadeDB: Double = 6

    /// The recording's loud level is the 95th percentile of its bars within
    /// `referenceWindowDB` of the loudest bar, so a few clicks or coughs don't
    /// shrink the rest and quiet pauses (far under the loudest bar) don't pull
    /// it down. It is never more than `loudestBarMarginDB` under the loudest
    /// bar, so a short remark in a long, hissy note keeps the hiss lower.
    static let referencePercentile: Double = 0.95
    static let referenceWindowDB: Double = 30
    static let loudestBarMarginDB: Double = 18

    /// The loud level draws at this height, and a bar's height is its RMS as a
    /// fraction of the loud level times this: the linear scale of the Mac's
    /// original RMS x8 bars for a normally loud recording, so ordinary speech
    /// 4-8 dB under the loud level sits at mid height and pauses draw low.
    /// Louder bars rise toward 1 without clipping, so a bar a little louder and
    /// one much louder still differ.
    public static let referenceHeight: Float = 0.9

    /// Bar heights (0...1) for a recording's samples, one bar per equal slice.
    /// Each bar is its slice's RMS measured against the recording's own loud
    /// level, so the same sound recorded quietly (an iPhone mic without
    /// automatic gain) or loudly draws the same shape. Silence, and background
    /// noise well under the loud level, stay at `floorHeight`. A recording
    /// that is one steady sound throughout has nothing quieter to compare
    /// with and draws at `referenceHeight`.
    public static func heights(from samples: [Float], barCount: Int = 80) -> [Float] {
        guard !samples.isEmpty, barCount > 0 else { return [] }

        let levelsDB = (0..<barCount).map { index -> Double in
            let start = min(samples.count - 1, samples.count * index / barCount)
            let end = max(start + 1, samples.count * (index + 1) / barCount)
            let sum = samples[start..<end].reduce(0.0) { partial, sample in
                partial + Double(sample) * Double(sample)
            }
            let rms = (sum / Double(end - start)).squareRoot()
            // A slice that isn't a number (a corrupt sample) draws as silence
            // rather than as the loudest bar, which would flatten the rest.
            return rms.isFinite ? 20 * log10(max(rms, 1e-10)) : -.infinity
        }

        let sounding = levelsDB.filter { $0 > silenceLevelDB }.sorted()
        guard let loudestDB = sounding.last else {
            return [Float](repeating: floorHeight, count: barCount)
        }
        let referenceDB = max(
            percentile(referencePercentile, of: sounding.filter { $0 >= loudestDB - referenceWindowDB }),
            loudestDB - loudestBarMarginDB
        )
        let topHeight = Double(referenceHeight)

        return levelsDB.map { levelDB in
            guard levelDB > silenceLevelDB else { return floorHeight }
            let relative = pow(10, (levelDB - referenceDB) / 20)
            let curve = relative <= 1 ? topHeight * relative : 1 - (1 - topHeight) / relative
            let height = curve * clamp((levelDB - silenceLevelDB) / silenceFadeDB)
            return max(floorHeight, Float(height))
        }
    }

    private static func percentile(_ fraction: Double, of sorted: [Double]) -> Double {
        sorted[Int((Double(sorted.count - 1) * fraction).rounded(.down))]
    }

    private static func clamp(_ value: Double) -> Double {
        min(1, max(0, value))
    }
}
