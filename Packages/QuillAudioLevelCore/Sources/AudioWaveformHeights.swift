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

    /// How far below the recording's loud level a bar still rises above the
    /// floor. A bar 15 dB under the loud level draws at about half height.
    static let displaySpanDB: Double = 30

    /// The recording's loud level is its 95th-percentile sounding bar, so one
    /// click doesn't shrink everything else, but never more than
    /// `loudestBarMarginDB` under its loudest bar, so a short remark in a long
    /// quiet note keeps its own loud and soft parts.
    static let referencePercentile: Double = 0.95
    static let loudestBarMarginDB: Double = 12

    /// The recording's noise floor is its 10th-percentile sounding bar. When
    /// the loud level stands well above it (fully from `noiseContrastDB` plus
    /// `noiseFadeDB`), bars within `noiseMarginDB` of the floor are background
    /// noise and draw flat, fading back in over `noiseFadeDB` above that. The
    /// fades keep a small change in level from switching bars on or off.
    static let noisePercentile: Double = 0.10
    static let noiseContrastDB: Double = 20
    static let noiseMarginDB: Double = 3
    static let noiseFadeDB: Double = 6

    /// Bar heights (0...1) for a recording's samples, one bar per equal slice.
    /// Each bar is its slice's RMS in dB, measured against the recording's own
    /// loud level, so the same sound recorded quietly (an iPhone mic without
    /// automatic gain) or loudly draws the same shape. Silence and background
    /// noise between sounds stay at `floorHeight`. A recording that is one
    /// steady sound throughout has nothing quieter to compare with and draws
    /// full bars.
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
            percentile(referencePercentile, of: sounding),
            loudestDB - loudestBarMarginDB
        )
        let noiseDB = percentile(noisePercentile, of: sounding)
        let noiseGate = clamp((referenceDB - noiseDB - noiseContrastDB) / noiseFadeDB)
        let bottomDB = referenceDB - displaySpanDB

        return levelsDB.map { levelDB in
            guard levelDB > silenceLevelDB else { return floorHeight }
            let aboveNoise = clamp((levelDB - noiseDB - noiseMarginDB) / noiseFadeDB)
            let fraction = clamp((levelDB - bottomDB) / displaySpanDB)
                * clamp((levelDB - silenceLevelDB) / silenceFadeDB)
                * (1 - noiseGate * (1 - aboveNoise))
            return floorHeight + (1 - floorHeight) * Float(fraction)
        }
    }

    private static func percentile(_ fraction: Double, of sorted: [Double]) -> Double {
        sorted[Int((Double(sorted.count - 1) * fraction).rounded(.down))]
    }

    private static func clamp(_ value: Double) -> Double {
        min(1, max(0, value))
    }
}
