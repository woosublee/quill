import Foundation

@main
struct SystemAudioDisplayLevelNormalizerTests {
    static func main() {
        testSilenceStaysHidden()
        testContinuousSystemAudioStaysVisible()
        testModerateSystemAudioChangesRemainVisible()
        print("SystemAudioDisplayLevelNormalizerTests passed")
    }

    private static func testSilenceStaysHidden() {
        var normalizer = SystemAudioDisplayLevelNormalizer()

        let level = normalizer.normalizedLevel(forRMS: 0)

        assert(level == 0)
    }

    private static func testContinuousSystemAudioStaysVisible() {
        var normalizer = SystemAudioDisplayLevelNormalizer()
        var level: Float = 0

        for _ in 0..<4 {
            level = normalizer.normalizedLevel(forRMS: 0.01)
        }

        assert(level > 0.45)
    }

    private static func testModerateSystemAudioChangesRemainVisible() {
        var normalizer = SystemAudioDisplayLevelNormalizer()
        var quietLevel: Float = 0
        var loudLevel: Float = 0

        for _ in 0..<4 {
            quietLevel = normalizer.normalizedLevel(forRMS: 0.01)
        }
        loudLevel = normalizer.normalizedLevel(forRMS: 0.04)

        assert(loudLevel - quietLevel > 0.08)
    }
}
