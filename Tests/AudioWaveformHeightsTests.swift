import Foundation

@main
struct AudioWaveformHeightsTests {
    static func main() {
        do {
            try mildlyBoostsQuietWaveform()
            try preservesAlreadyVisibleWaveformScale()
            try returnsNoHeightsForEmptySamples()
            print("AudioWaveformHeightsTests passed")
        } catch {
            fputs("AudioWaveformHeightsTests failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func mildlyBoostsQuietWaveform() throws {
        let heights = AudioWaveformHeights.heights(from: [0.005, -0.005, 0.005, -0.005], barCount: 4)

        try expectEqual(heights, [0.12, 0.12, 0.12, 0.12], "quiet waveform should be boosted gently")
    }

    private static func preservesAlreadyVisibleWaveformScale() throws {
        let heights = AudioWaveformHeights.heights(from: [0.05, -0.05, 0.05, -0.05], barCount: 4)

        try expectEqual(heights, [0.4, 0.4, 0.4, 0.4], "already visible waveform should keep the existing scale")
    }

    private static func returnsNoHeightsForEmptySamples() throws {
        let heights = AudioWaveformHeights.heights(from: [], barCount: 4)

        try expectEqual(heights, [], "empty samples should not produce waveform bars")
    }

    private static func expectEqual(_ actual: [Float], _ expected: [Float], _ label: String) throws {
        guard actual.count == expected.count else {
            throw TestFailure("\(label): expected count \(expected.count), got \(actual.count)")
        }
        for (index, pair) in zip(actual, expected).enumerated() {
            guard abs(pair.0 - pair.1) < 0.0001 else {
                throw TestFailure("\(label) at index \(index): expected \(pair.1), got \(pair.0)")
            }
        }
    }

    private struct TestFailure: Error, CustomStringConvertible {
        let description: String

        init(_ description: String) {
            self.description = description
        }
    }
}
