import Foundation

enum AudioWaveformHeights {
    struct Layout {
        let barCount: Int
        let barWidth: CGFloat
        let gap: CGFloat
    }

    static func layout(width: CGFloat, barCount: Int = 80, preferredGap: CGFloat = 2) -> Layout {
        guard width > 0, barCount > 0 else {
            return Layout(barCount: 0, barWidth: 0, gap: 0)
        }

        let minimumBarWidth: CGFloat = 1
        let maxGap = barCount > 1
            ? max(0, (width - CGFloat(barCount) * minimumBarWidth) / CGFloat(barCount - 1))
            : 0
        let gap = min(preferredGap, maxGap)
        let totalGap = gap * CGFloat(max(0, barCount - 1))
        let barWidth = max(0, (width - totalGap) / CGFloat(barCount))

        return Layout(barCount: barCount, barWidth: barWidth, gap: gap)
    }

    static func heights(from samples: [Float], barCount: Int = 80) -> [Float] {
        guard !samples.isEmpty, barCount > 0 else { return [] }

        let bucketSize = max(1, samples.count / barCount)
        let rawHeights = (0..<barCount).map { index -> Float in
            let start = index * bucketSize
            guard start < samples.count else { return 0 }

            let end = min(start + bucketSize, samples.count)
            let sum = samples[start..<end].reduce(Float(0)) { partial, sample in
                partial + sample * sample
            }
            return sqrt(sum / Float(end - start)) * 8
        }

        let peakHeight = rawHeights.max() ?? 0
        let displayGain = peakHeight > 0 && peakHeight < 0.24 ? min(3, 0.24 / peakHeight) : 1

        return rawHeights.map { height in
            min(1, max(0.04, height * displayGain))
        }
    }
}
