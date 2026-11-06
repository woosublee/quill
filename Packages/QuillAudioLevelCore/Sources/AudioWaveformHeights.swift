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

    /// A drawn bar's width and the narrowest space between bars. They stay the
    /// same at every size, so a wider card shows more bars rather than wider ones.
    public static let barWidth: CGFloat = 1
    public static let minimumBarGap: CGFloat = 2

    /// How many slices a recording's levels are measured at, and the most bars
    /// a card draws. A wider card spaces its bars out.
    public static let sourceSliceCount = 480

    /// As many bars as fit the width, up to `sourceSliceCount`. The space left
    /// over goes between them, so the bars reach both ends.
    public static func fittedLayout(width: CGFloat) -> Layout {
        guard width.isFinite, width >= barWidth else {
            return Layout(barCount: 0, barWidth: 0, gap: 0)
        }
        let fitting = Int((width + minimumBarGap) / (barWidth + minimumBarGap))
        let barCount = min(fitting, sourceSliceCount)
        let gap = barCount > 1
            ? (width - CGFloat(barCount) * barWidth) / CGFloat(barCount - 1)
            : 0
        return Layout(barCount: barCount, barWidth: barWidth, gap: gap)
    }

    /// How many bars, from the left, draw as played at `progress` (0...1) of
    /// `width`. A bar counts once the position reaches its left edge, so the bar
    /// under the pointer turns played when a click or drag lands on it.
    public static func playedBarCount(layout: Layout, width: CGFloat, progress: Double) -> Int {
        let step = layout.barWidth + layout.gap
        guard layout.barCount > 0, progress.isFinite, progress > 0, width.isFinite, step > 0 else { return 0 }
        let position = width * CGFloat(min(progress, 1))
        return min(layout.barCount, Int(position / step) + 1)
    }

    /// A recording's RMS level in each of `sliceCount` equal slices. Keep these,
    /// not heights: `heights(fromSliceLevels:barCount:)` turns them into the
    /// bars that fit, and a recording's loud level depends on the bar count.
    public static func sliceLevels(from samples: [Float], sliceCount: Int = sourceSliceCount) -> [Double] {
        guard !samples.isEmpty, sliceCount > 0 else { return [] }
        return (0..<sliceCount).map { index in
            let start = min(samples.count - 1, samples.count * index / sliceCount)
            let end = max(start + 1, samples.count * (index + 1) / sliceCount)
            let sum = samples[start..<end].reduce(0.0) { partial, sample in
                partial + Double(sample) * Double(sample)
            }
            let rms = (sum / Double(end - start)).squareRoot()
            // A slice that isn't a number (a corrupt sample) counts as silence.
            return rms.isFinite ? rms : 0
        }
    }

    /// Bar heights for `barCount` bars, the same as measuring the recording at
    /// that many bars: slices in one bar combine by power, then the loud level
    /// is worked out across the bars. With fewer slices than bars, a slice
    /// spreads over its neighbors.
    public static func heights(fromSliceLevels levels: [Double], barCount: Int) -> [Float] {
        guard !levels.isEmpty, barCount > 0 else { return [] }
        let levelsDB = (0..<barCount).map { index -> Double in
            let start = min(levels.count - 1, levels.count * index / barCount)
            let end = max(start + 1, levels.count * (index + 1) / barCount)
            let power = levels[start..<end].reduce(0.0) { $0 + $1 * $1 } / Double(end - start)
            return 20 * log10(max(power.squareRoot(), 1e-10))
        }
        return heights(levelsDB: levelsDB, barCount: barCount)
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
        return heights(levelsDB: levelsDB, barCount: barCount)
    }

    private static func heights(levelsDB: [Double], barCount: Int) -> [Float] {
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
