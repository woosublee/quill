import Foundation

@main
struct AudioImportOptionsTests {
    static func main() {
        testAPIStandardSupportsAllImportExtensions()
        testAPIRealtimeFallsBackToAPIStandardForImport()
        testLocalCurrentModeDefaultsToLocalWhisper()
        testAPIKeyMissingFallsBackToLocalWhisper()
        testNoAvailableBackendReturnsNoDefault()
        testStorageExtensionPreservesSupportedImportExtension()
        testStorageExtensionFallsBackToWavForUnknownExtension()
        testImportedAudioContextSummaryIsEmpty()
        testAPIStandardDisabledAboveTwentyFiveMegabytes()
        testLocalWhisperStillEnabledAboveTwentyFiveMegabytes()
        testNativeLocalWhisperDoesNotSupportWebMImport()
        print("AudioImportOptionsTests passed")
    }

    private static func testAPIStandardSupportsAllImportExtensions() {
        let options = AudioImportOptions(
            fileExtension: "webm",
            currentMode: .apiStandard,
            hasAPIKey: true,
            hasLocalWhisperModel: true
        )

        assert(options.defaultMode == .apiStandard)
        assert(options.supportedModes.contains(.apiStandard))
        assert(!options.supportedModes.contains(.apiRealtime))
        assert(!options.supportedModes.contains(.localWhisper))
        assert(!options.supportedModes.contains(.localAppleLive))
    }

    private static func testAPIRealtimeFallsBackToAPIStandardForImport() {
        let options = AudioImportOptions(
            fileExtension: "mp3",
            currentMode: .apiRealtime,
            hasAPIKey: true,
            hasLocalWhisperModel: true
        )

        assert(options.defaultMode == .apiStandard)
    }

    private static func testLocalCurrentModeDefaultsToLocalWhisper() {
        let options = AudioImportOptions(
            fileExtension: "m4a",
            currentMode: .localAppleLive,
            hasAPIKey: true,
            hasLocalWhisperModel: true
        )

        assert(options.defaultMode == .localWhisper)
        assert(options.supportedModes == [.apiStandard, .localWhisper])
    }

    private static func testAPIKeyMissingFallsBackToLocalWhisper() {
        let options = AudioImportOptions(
            fileExtension: "mp3",
            currentMode: .apiStandard,
            hasAPIKey: false,
            hasLocalWhisperModel: true
        )

        assert(!options.supportedModes.contains(.apiStandard))
        assert(options.defaultMode == .localWhisper)
    }

    private static func testNoAvailableBackendReturnsNoDefault() {
        let options = AudioImportOptions(
            fileExtension: "mp3",
            currentMode: .apiStandard,
            hasAPIKey: false,
            hasLocalWhisperModel: false
        )

        assert(options.supportedModes.isEmpty)
        assert(options.defaultMode == nil)
    }

    private static func testStorageExtensionPreservesSupportedImportExtension() {
        assert(AudioImportOptions.storageExtension(for: "meeting.MP3") == "mp3")
        assert(AudioImportOptions.storageExtension(for: "clip.webm") == "webm")
    }

    private static func testStorageExtensionFallsBackToWavForUnknownExtension() {
        assert(AudioImportOptions.storageExtension(for: "audio.xyz") == "wav")
        assert(AudioImportOptions.storageExtension(for: "audio") == "wav")
    }

    private static func testImportedAudioContextSummaryIsEmpty() {
        assert(AudioImportOptions.importContextSummary(for: "새로운.m4a") == "")
    }

    private static func testAPIStandardDisabledAboveTwentyFiveMegabytes() {
        let options = AudioImportOptions(
            fileExtension: "mp3",
            currentMode: .apiStandard,
            fileSizeBytes: AudioImportOptions.apiUploadLimitBytes + 1,
            hasAPIKey: true,
            hasLocalWhisperModel: true
        )

        assert(!options.supportedModes.contains(.apiStandard))
        assert(options.defaultMode == .localWhisper)
    }

    private static func testLocalWhisperStillEnabledAboveTwentyFiveMegabytes() {
        let options = AudioImportOptions(
            fileExtension: "mp3",
            currentMode: .localWhisper,
            fileSizeBytes: AudioImportOptions.apiUploadLimitBytes + 1,
            hasAPIKey: true,
            hasLocalWhisperModel: true
        )

        assert(options.supportedModes.contains(.localWhisper))
    }

    private static func testNativeLocalWhisperDoesNotSupportWebMImport() {
        let options = AudioImportOptions(
            fileExtension: "webm",
            currentMode: .localWhisper,
            hasAPIKey: false,
            hasLocalWhisperModel: true
        )

        assert(!options.supportedModes.contains(.apiStandard))
        assert(!options.supportedModes.contains(.localWhisper))
        assert(options.defaultMode == nil)
        assert(options.localWhisperUnavailableReason == "Local Whisper supports MP3, MP4, M4A, MPEG, MPGA, and WAV imports")
    }
}
