import Foundation
import QuillAudioLevelCore

@main
struct AudioWaveformHeightsTests {
    static let referenceHeight = AudioWaveformHeights.referenceHeight
    static let tall = referenceHeight - 0.01

    static func main() {
        do {
            try quietAndLoudRecordingsOfTheSameShapeDrawTheSameBars()
            try speechSitsMidHeightWithPausesLow()
            try silenceAndFaintNoiseStayFlat()
            try oneLoudClickDoesNotFlattenTheRest()
            try twoClicksDoNotFlattenTheRest()
            try aOneBarRemarkOverHissKeepsTheHissLow()
            try aOneBarRemarkOverCloserHissKeepsTheHissLower()
            try aMostlySilentRecordingKeepsItsDynamics()
            try measuresEverySampleAndDrawsShortClipsWithoutPadding()
            try backgroundNoiseBetweenSoundsStaysFlat()
            try barsFadeInAboveTheSilenceLevel()
            try aCorruptSliceDoesNotFlattenTheRest()
            try leadingZerosDoNotHideTheNoiseFloor()
            try returnsNoHeightsForEmptySamples()
            try fitsBarsInsideAvailableWidth()
            try clampsNegativePreferredGap()
            try aWiderCardShowsMoreBarsOfTheSameWidth()
            try fittedBarsReachBothEnds()
            try theBarUnderThePointerDrawsPlayed()
            try sliceLevelsMatchMeasuringAtTheBarCount()
            try heightsFromSliceLevelsHandleFewOrNoSlices()
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
        try expect(abs((quiet.max() ?? 0) - referenceHeight) < 0.001, "the loud part of a quiet recording draws at the reference height")
        try expect(quiet.min() == AudioWaveformHeights.floorHeight, "the silent gaps stay at the floor")
        let half = quiet[8], quarter = quiet[16]
        try expect(abs(half - referenceHeight * 0.5) < 0.01 && abs(quarter - referenceHeight * 0.25) < 0.01, "quieter steps draw shorter bars: \(half), \(quarter)")
    }

    /// Synthetic speech: syllable bursts (120-280 ms, loudness varying about
    /// +-6 dB, 40-120 ms apart) in phrases of 3-9 syllables, with 0.8-2.5 s
    /// pauses between phrases, over a little room noise. Returns the samples
    /// and, per bar, whether the bar holds speech.
    private static func syntheticSpeech(peak: Float, noise: Float) -> (samples: [Float], speechBars: [Bool]) {
        var state: UInt64 = 42
        func random() -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(state >> 40) / Float(1 << 24)
        }
        let rate = 16_000, total = 60 * rate
        var samples = [Float](repeating: 0, count: total)
        var speechEnergy = [Float](repeating: 0, count: 80)
        var time = rate / 2
        while time < total {
            for _ in 0..<(3 + Int(random() * 7)) where time < total {
                let length = Int((0.12 + random() * 0.16) * Float(rate))
                let gain = peak * pow(10, (random() * 12 - 6) / 20)
                let frequency = 120 + random() * 120
                for offset in 0..<length where time + offset < total {
                    let index = time + offset
                    let phase = 2 * Float.pi * frequency * Float(index) / Float(rate)
                    samples[index] = gain * sin(.pi * Float(offset) / Float(length))
                        * (0.7 * sin(phase) + 0.3 * sin(3 * phase))
                    speechEnergy[index * 80 / total] += 1
                }
                time += length + Int((0.04 + random() * 0.08) * Float(rate))
            }
            time += Int((0.8 + random() * 1.7) * Float(rate))
        }
        for index in 0..<total { samples[index] += (random() - 0.5) * 2 * noise }
        // A bar is speech when syllables fill at least a fifth of it.
        return (samples, speechEnergy.map { $0 >= Float(total / 80) / 5 })
    }

    // Normal speech draws mid-height bars like the Mac's old waveform of a
    // normally loud recording: only the loudest moments reach near the top,
    // and pauses stay low (2026-11-02 device feedback: "too big everywhere").
    private static func speechSitsMidHeightWithPausesLow() throws {
        let loud = syntheticSpeech(peak: 0.25, noise: 0.002)        // a Mac mic with automatic gain
        let quiet = syntheticSpeech(peak: 0.008, noise: 0.000_06)   // about 30 dB quieter, an iPhone mic
        let loudHeights = AudioWaveformHeights.heights(from: loud.samples)
        let quietHeights = AudioWaveformHeights.heights(from: quiet.samples)

        for (index, pair) in zip(quietHeights, loudHeights).enumerated() {
            try expect(abs(pair.0 - pair.1) < 0.02, "bar \(index) matches: quiet \(pair.0), loud \(pair.1)")
        }
        let speech = zip(loudHeights, loud.speechBars).filter { $0.1 }.map { $0.0 }.sorted()
        let pauses = zip(loudHeights, loud.speechBars).filter { !$0.1 }.map { $0.0 }.sorted()
        try expect(speech.count >= 30 && pauses.count >= 5, "the fixture has speech and pauses")
        let median = speech[speech.count / 2]
        try expect(median >= 0.35 && median <= 0.7, "speech sits mid-height: median \(median)")
        try expect(speech.filter { $0 >= 0.85 }.count <= speech.count / 5, "only the loudest moments reach the top")
        let top = loudHeights.max() ?? 0
        try expect(top >= 0.85 && top <= 1, "the loudest bar reaches near the top: \(top)")
        try expect(pauses[pauses.count / 2] <= 0.08, "pauses stay low: median \(pauses[pauses.count / 2])")
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

    private static func twoClicksDoNotFlattenTheRest() throws {
        var samples = syntheticRecording(peak: 0.05)
        for start in [6_400, 48_000] {
            for index in 0..<200 { samples[start + index] = 0.99 }
        }
        let heights = AudioWaveformHeights.heights(from: samples)
        try expect(heights.filter { $0 > 0.6 }.count >= 20, "the loud steps stay tall next to two clicks")
    }

    // A cough or short remark that fits in one bar of a long hissy note.
    private static func aOneBarRemarkOverHissKeepsTheHissLow() throws {
        var samples = noise(count: 80 * 1_000, peak: 0.003)
        for index in 0..<800 { samples[40_100 + index] += 0.3 * sin(Float(index) / 3) }
        let heights = AudioWaveformHeights.heights(from: samples)
        try expect(heights[40] > 0.5, "the remark stands up: \(heights[40])")
        try expect(heights[10] == 0.04 && heights[70] == 0.04, "the hiss stays flat")
    }

    // Room noise about 25 dB under a remark that fills one bar stays well
    // under the remark rather than becoming the loud level.
    private static func aOneBarRemarkOverCloserHissKeepsTheHissLower() throws {
        var samples = noise(count: 80 * 1_000, peak: 0.01)
        for index in 0..<1_000 { samples[40_000 + index] += 0.15 * sin(Float(index) / 3) }
        let heights = AudioWaveformHeights.heights(from: samples)
        try expect(heights[40] >= tall, "the remark is tall: \(heights[40])")
        try expect(heights[10] < 0.45 && heights[70] < 0.45, "the hiss stays lower: \(heights[10])")
    }

    // A long silent note with one short remark keeps the remark's own
    // loud and soft parts instead of clipping everything to full.
    private static func aMostlySilentRecordingKeepsItsDynamics() throws {
        var samples = [Float](repeating: 0, count: 80 * 1_000)
        for index in 0..<3_000 { samples[10_000 + index] = 0.5 * sin(Float(index) / 3) }
        for index in 0..<1_000 { samples[50_000 + index] = 0.05 * sin(Float(index) / 3) }
        let heights = AudioWaveformHeights.heights(from: samples)

        try expect(heights[10] >= tall && heights[12] >= tall, "the loud remark is tall")
        try expect(heights[50] > 0.04 && heights[50] < 0.5, "the soft remark stays short: \(heights[50])")
        try expect(heights[30] == 0.04, "silence stays flat")
    }

    // Every sample counts, the last slice included, and a clip shorter than
    // the bar count stretches across every bar instead of padding with silence.
    private static func measuresEverySampleAndDrawsShortClipsWithoutPadding() throws {
        var samples = [Float](repeating: 0, count: 159)
        samples[158] = 0.5
        let heights = AudioWaveformHeights.heights(from: samples)
        try expect(heights.count == 80 && heights[79] >= tall, "the last sample is in the last bar")

        let short = AudioWaveformHeights.heights(from: [0.5, -0.5, 0.5], barCount: 80)
        try expect(short.count == 80 && short.allSatisfy { $0 >= tall }, "a three-sample clip fills every bar")
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

        try expect(heights[40] >= tall && heights[42] >= tall, "the remark is tall")
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
        try expect((heights.max() ?? 0) >= tall, "the rest keeps its height")
    }

    // Exact zeros at the start (mic warm-up) don't count as the noise floor.
    private static func leadingZerosDoNotHideTheNoiseFloor() throws {
        var samples = noise(count: 80 * 1_000, peak: 0.003)
        for index in 0..<20_000 { samples[index] = 0 }
        for index in 0..<3_000 { samples[40_000 + index] += 0.3 * sin(Float(index) / 3) }
        let heights = AudioWaveformHeights.heights(from: samples)
        try expect(heights[40] >= tall, "the remark is tall")
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

    private static func aWiderCardShowsMoreBarsOfTheSameWidth() throws {
        let phone = AudioWaveformHeights.fittedLayout(width: 226)
        let tablet = AudioWaveformHeights.fittedLayout(width: 510)
        try expect(phone.barWidth == tablet.barWidth, "bar width stays the same at every size")
        try expect(tablet.barCount > phone.barCount * 2, "the wider card shows more bars")
        try expect(AudioWaveformHeights.fittedLayout(width: 0).barCount == 0, "no width, no bars")
        try expect(AudioWaveformHeights.fittedLayout(width: 0.5).barCount == 0, "too narrow for a bar")
        try expect(AudioWaveformHeights.fittedLayout(width: .infinity).barCount == 0, "infinite width doesn't trap")
        let wide = AudioWaveformHeights.fittedLayout(width: 4_000)
        try expect(wide.barCount == AudioWaveformHeights.sourceSliceCount, "very wide cards stop adding bars")
        try expect(AudioWaveformHeights.fittedLayout(width: 1).barCount == 1, "one bar fits")
    }

    private static func fittedBarsReachBothEnds() throws {
        for width: CGFloat in [10, 97, 226, 511] {
            let layout = AudioWaveformHeights.fittedLayout(width: width)
            let total = CGFloat(layout.barCount) * layout.barWidth + CGFloat(layout.barCount - 1) * layout.gap
            try expect(abs(total - width) < 0.001, "bars fill width \(width)")
            try expect(layout.gap >= AudioWaveformHeights.minimumBarGap, "bars keep their gap at \(width)")
        }
    }

    // Break caught: with 1 pt bars, the played count came from the progress
    // times the bar count, so a click or drag right on a bar left that bar (and
    // often one before it) unplayed: the tall bar under the pointer stayed grey.
    // Checked at the drawn (pixel-rounded) edge, and at widths where the trip
    // through a fraction comes back a hair short.
    private static func theBarUnderThePointerDrawsPlayed() throws {
        for width: CGFloat in [226, 333.3, 510, 1_439] {
            let layout = AudioWaveformHeights.fittedLayout(width: width)
            for scale: CGFloat in [1, 2, 3] {
                for index in 1..<layout.barCount {
                    let left = AudioWaveformHeights.barX(index, layout: layout, displayScale: scale)
                    for x in [left, left + layout.barWidth / 2, left + layout.barWidth] {
                        let played = AudioWaveformHeights.playedBarCount(
                            layout: layout, progress: Double(x / width), displayScale: scale
                        )
                        try expect(
                            played == index + 1,
                            "width \(width) @\(scale)x: pointer on bar \(index) at \(x) plays it and no more, got \(played)"
                        )
                    }
                }
            }
            // Bar 0 starts at 0, where nothing has played yet; any step in plays it.
            try expect(AudioWaveformHeights.playedBarCount(layout: layout, progress: 0, displayScale: 2) == 0, "start plays nothing")
            try expect(AudioWaveformHeights.playedBarCount(layout: layout, progress: 0.0001, displayScale: 2) == 1, "first step plays bar 0")
            try expect(AudioWaveformHeights.playedBarCount(layout: layout, progress: 1, displayScale: 2) == layout.barCount, "end plays all")
            try expect(AudioWaveformHeights.playedBarCount(layout: layout, progress: 2, displayScale: 2) == layout.barCount, "past the end plays all")
            try expect(AudioWaveformHeights.playedBarCount(layout: layout, progress: .nan, displayScale: 2) == 0, "NaN plays nothing")
        }
        let empty = AudioWaveformHeights.fittedLayout(width: 0)
        try expect(AudioWaveformHeights.playedBarCount(layout: empty, progress: 0.5, displayScale: 2) == 0, "no bars")
    }

    // Break caught: heights measured at 480 bars and combined later drew quieter
    // speech than the same recording measured at the bars it shows.
    private static func sliceLevelsMatchMeasuringAtTheBarCount() throws {
        let samples = (0..<96_000).map { index -> Float in
            let syllable = sin(Float(index) / 2_400) > 0 ? Float(0.2) : Float(0.02)
            return syllable * sin(Float(index) / 7)
        }
        let levels = AudioWaveformHeights.sliceLevels(from: samples, sliceCount: 480)
        let combined = AudioWaveformHeights.heights(fromSliceLevels: levels, barCount: 80)
        let measured = AudioWaveformHeights.heights(from: samples, barCount: 80)
        try expect(combined.count == 80, "one height per bar")
        for (index, height) in combined.enumerated() {
            try expect(abs(height - measured[index]) < 0.01, "bar \(index) draws the same")
        }
    }

    private static func heightsFromSliceLevelsHandleFewOrNoSlices() throws {
        try expect(AudioWaveformHeights.heights(fromSliceLevels: [], barCount: 3).isEmpty, "no slices, no bars")
        try expect(AudioWaveformHeights.heights(fromSliceLevels: [0.2], barCount: 3).count == 3, "one slice spreads")
        try expect(AudioWaveformHeights.sliceLevels(from: []).isEmpty, "no samples, no levels")
        let corrupt = AudioWaveformHeights.sliceLevels(from: [Float.nan, 0.5], sliceCount: 2)
        try expect(corrupt[0] == 0, "a corrupt slice counts as silence")
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
