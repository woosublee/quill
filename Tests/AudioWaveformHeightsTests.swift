import Foundation
import QuillAudioLevelCore

@main
struct AudioWaveformHeightsTests {
    static func main() {
        do {
            try quietAndLoudRecordingsOfTheSameShapeDrawTheSameBars()
            try silenceAndFaintNoiseStayFlat()
            try oneLoudClickDoesNotFlattenTheRest()
            try aMostlySilentRecordingKeepsItsDynamics()
            try measuresEverySampleAndDrawsShortClipsWithoutPadding()
            try backgroundNoiseBetweenSoundsStaysFlat()
            try barsFadeInAboveTheSilenceLevel()
            try aCorruptSliceDoesNotFlattenTheRest()
            try leadingZerosDoNotHideTheNoiseFloor()
            try returnsNoHeightsForEmptySamples()
            try fitsBarsInsideAvailableWidth()
            try clampsNegativePreferredGap()
            try meterLevelFollowsAFixedSequence()
            try meterStaysQuietInSilenceAndVisibleWhenLoud()
            print("AudioWaveformHeightsTests passed")
        } catch {
            fputs("AudioWaveformHeightsTests failed: \(error)\n", stderr)
            exit(1)
        }
    }

    /// Synthetic 8-second recording at 16 kHz: a 220 Hz tone in steps of
    /// full, half, and quarter loudness with silent gaps, each step 0.4 s so
    /// every one of the 80 bars falls inside one step.
    private static func syntheticRecording(peak: Float) -> [Float] {
        let steps: [Float] = [0, 1, 0.5, 0, 0.25, 1, 0, 0.5, 1, 0.25, 0, 1, 0.5, 0.25, 0, 1, 0, 0.5, 1, 0]
        return (0..<(16_000 * 8)).map { index in
            let gain = steps[index / 6_400]
            return peak * gain * sin(2 * .pi * 220 * Float(index) / 16_000)
        }
    }

    // An iPhone recording (measurement mode, no automatic gain) is about 40 dB
    // quieter than a Mac one of the same speech; it drew an almost flat
    // waveform (2026-11-02).
    private static func quietAndLoudRecordingsOfTheSameShapeDrawTheSameBars() throws {
        let quiet = AudioWaveformHeights.heights(from: syntheticRecording(peak: 0.003))
        let loud = AudioWaveformHeights.heights(from: syntheticRecording(peak: 0.3))

        try expect(quiet.count == 80 && loud.count == 80, "both recordings draw 80 bars")
        try expectEqual(quiet, loud, "quiet and loud recordings of the same shape")
        try expect((quiet.max() ?? 0) == 1, "the loud part of a quiet recording reaches full height")
        try expect(quiet.min() == AudioWaveformHeights.floorHeight, "the silent gaps stay at the floor")
        let half = quiet[8], quarter = quiet[16]
        try expect(half > quarter && half < 1 && quarter > 0.5, "quieter steps draw shorter bars: \(half), \(quarter)")
    }

    private static func silenceAndFaintNoiseStayFlat() throws {
        let silence = AudioWaveformHeights.heights(from: [Float](repeating: 0, count: 16_000), barCount: 80)
        try expectEqual(silence, [Float](repeating: 0.04, count: 80), "digital silence")

        // Room noise around -75 dBFS is below the silence level.
        var seed: UInt32 = 1
        let noise = (0..<16_000).map { _ -> Float in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return (Float(seed >> 8) / Float(1 << 24) - 0.5) * 0.0006
        }
        let noiseHeights = AudioWaveformHeights.heights(from: noise, barCount: 80)
        try expectEqual(noiseHeights, [Float](repeating: 0.04, count: 80), "faint noise")
    }

    private static func oneLoudClickDoesNotFlattenTheRest() throws {
        var samples = syntheticRecording(peak: 0.05)
        for index in 0..<200 { samples[6_400 + index] = 0.99 }
        let heights = AudioWaveformHeights.heights(from: samples)

        try expect(heights.filter { $0 > 0.6 }.count >= 20, "the loud steps stay tall next to a click")
    }

    // A long silent note with one short remark keeps the remark's own
    // loud and soft parts instead of clipping everything to full.
    private static func aMostlySilentRecordingKeepsItsDynamics() throws {
        var samples = [Float](repeating: 0, count: 80 * 1_000)
        for index in 0..<3_000 { samples[10_000 + index] = 0.5 * sin(Float(index) / 3) }
        for index in 0..<1_000 { samples[50_000 + index] = 0.05 * sin(Float(index) / 3) }
        let heights = AudioWaveformHeights.heights(from: samples)

        try expect(heights[10] > 0.98 && heights[12] > 0.98, "the loud remark is full")
        try expect(heights[50] > 0.04 && heights[50] < 0.5, "the soft remark stays short: \(heights[50])")
        try expect(heights[30] == 0.04, "silence stays flat")
    }

    // Every sample counts, the last slice included, and a clip shorter than
    // the bar count stretches across every bar instead of padding with silence.
    private static func measuresEverySampleAndDrawsShortClipsWithoutPadding() throws {
        var samples = [Float](repeating: 0, count: 159)
        samples[158] = 0.5
        let heights = AudioWaveformHeights.heights(from: samples)
        try expect(heights.count == 80 && heights[79] > 0.98, "the last sample is in the last bar")

        let short = AudioWaveformHeights.heights(from: [0.5, -0.5, 0.5], barCount: 80)
        try expect(short.count == 80 && short.allSatisfy { $0 > 0.98 }, "a three-sample clip fills every bar")
    }

    private static func noise(count: Int, peak: Float) -> [Float] {
        var seed: UInt32 = 7
        return (0..<count).map { _ in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return (Float(seed >> 8) / Float(1 << 24) - 0.5) * 2 * peak
        }
    }

    // Fan hiss at about -55 dBFS with one short remark: the hiss stays flat
    // and the remark stands tall.
    private static func backgroundNoiseBetweenSoundsStaysFlat() throws {
        var samples = noise(count: 80 * 1_000, peak: 0.003)
        for index in 0..<3_000 { samples[40_000 + index] += 0.3 * sin(Float(index) / 3) }
        let heights = AudioWaveformHeights.heights(from: samples)

        try expect(heights[40] > 0.98 && heights[42] > 0.98, "the remark is full")
        try expect(heights[10] == 0.04 && heights[70] == 0.04, "the hiss stays flat")
    }

    // Quiet speech near the silence level fades in instead of jumping from
    // flat to half height across one dB.
    private static func barsFadeInAboveTheSilenceLevel() throws {
        let levels: [Float] = [0.01, pow(10, -71.5 / 20), pow(10, -66.5 / 20)]
        let heights = AudioWaveformHeights.heights(from: levels, barCount: 3)
        try expect(heights[1] < 0.15, "a bar just above the silence level stays short: \(heights[1])")
        try expect(heights[2] > heights[1], "a louder bar draws taller")
    }

    private static func aCorruptSliceDoesNotFlattenTheRest() throws {
        var samples = syntheticRecording(peak: 0.003)
        samples[100] = .nan
        let heights = AudioWaveformHeights.heights(from: samples)
        try expect(heights[0] == 0.04, "the corrupt slice draws as silence")
        try expect((heights.max() ?? 0) > 0.98, "the rest keeps its full height")
    }

    // Exact zeros at the start (mic warm-up) don't count as the noise floor.
    private static func leadingZerosDoNotHideTheNoiseFloor() throws {
        var samples = noise(count: 80 * 1_000, peak: 0.003)
        for index in 0..<20_000 { samples[index] = 0 }
        for index in 0..<3_000 { samples[40_000 + index] += 0.3 * sin(Float(index) / 3) }
        let heights = AudioWaveformHeights.heights(from: samples)
        try expect(heights[40] > 0.98, "the remark is full")
        try expect(heights[70] == 0.04, "the hiss after the zeros stays flat")
    }

    private static func returnsNoHeightsForEmptySamples() throws {
        let heights = AudioWaveformHeights.heights(from: [], barCount: 4)

        try expectEqual(heights, [], "empty samples should not produce waveform bars")
    }

    private static func fitsBarsInsideAvailableWidth() throws {
        let layout = AudioWaveformHeights.layout(width: 210, barCount: 80, preferredGap: 2)
        let totalWidth = CGFloat(layout.barCount) * layout.barWidth
            + CGFloat(layout.barCount - 1) * layout.gap

        try expect(layout.barCount == 80, "wide-enough waveform should preserve all bars")
        try expect(totalWidth <= 210.0001, "wide-enough waveform should fit inside available width")

        let narrowLayout = AudioWaveformHeights.layout(width: 96, barCount: 80, preferredGap: 2)
        let narrowTotalWidth = CGFloat(narrowLayout.barCount) * narrowLayout.barWidth
            + CGFloat(narrowLayout.barCount - 1) * narrowLayout.gap

        try expect(narrowLayout.barCount == 80, "narrow waveform should preserve all bars")
        try expect(narrowTotalWidth <= 96.0001, "narrow waveform should fit inside available width")
    }

    private static func clampsNegativePreferredGap() throws {
        let layout = AudioWaveformHeights.layout(width: 96, barCount: 80, preferredGap: -2)
        let totalWidth = CGFloat(layout.barCount) * layout.barWidth
            + CGFloat(layout.barCount - 1) * layout.gap

        try expect(layout.gap >= 0, "negative preferred gap should be clamped to non-negative spacing")
        try expect(totalWidth <= 96.0001, "negative preferred gap layout should still fit inside available width")
    }

    // Values from the meter before it moved to QuillAudioLevelCore.
    private static func meterLevelFollowsAFixedSequence() throws {
        var normalizer = LiveAudioLevelNormalizer()
        let levels = [Float(0), 0.001, 0.02, 0.2, 0.2, 0.05, 0.001, 0].map {
            normalizer.normalizedLevel(forRMS: $0)
        }
        try expectEqual(
            levels,
            [0, 0, 0.361674, 0.648921, 0.774212, 0.764227, 0.672519, 0.591817],
            "meter levels"
        )
        normalizer.reset()
        var fresh = LiveAudioLevelNormalizer()
        try expect(
            normalizer.normalizedLevel(forRMS: 0.02) == fresh.normalizedLevel(forRMS: 0.02),
            "reset restores the starting state"
        )
    }

    private static func meterStaysQuietInSilenceAndVisibleWhenLoud() throws {
        var silent = LiveAudioLevelNormalizer()
        var silentLevel: Float = 1
        for _ in 0..<50 { silentLevel = silent.normalizedLevel(forRMS: 0) }
        try expect(silentLevel == 0, "silence stays at 0")

        var loud = LiveAudioLevelNormalizer()
        var loudLevel: Float = 0
        for _ in 0..<50 { loudLevel = loud.normalizedLevel(forRMS: 0.3) }
        try expect(loudLevel >= 0.12 && loudLevel <= 1, "a sustained loud signal stays visible and in range")
    }

    private static func expect(_ condition: Bool, _ label: String) throws {
        guard condition else { throw TestFailure(label) }
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
