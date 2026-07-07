import Foundation

@main
struct AudioImportOptionsTests {
    static func main() {
        testAPIStandardSupportsBroadImportExtensions()
        testAPIRealtimeFallsBackToAPIStandardForImport()
        testNativeCurrentChoiceDefaultsToNativeWhisper()
        testLegacyCurrentChoiceDefaultsToSameLegacyModel()
        testAPIKeyMissingFallsBackToLocalWhisper()
        testNoAvailableBackendReturnsNoDefault()
        testStorageExtensionPreservesSupportedImportExtension()
        testStorageExtensionFallsBackToWavForUnknownExtension()
        testImportedAudioContextSummaryIsEmpty()
        testAPIStandardDisabledAboveTwentyFiveMegabytes()
        testLocalWhisperStillEnabledAboveTwentyFiveMegabytes()
        testWebMDisablesNativeButAllowsInstalledLegacyImport()
        testNativeAndLegacyRowsAreShownTogether()
        print("AudioImportOptionsTests passed")
    }

    private static let apiChoice = TranscriptionBackendChoice.apiStandard(modelID: "whisper-large-v3")
    private static let nativeChoice = TranscriptionBackendChoice.nativeWhisper(modelID: AudioImportOptions.fallbackNativeWhisperModelID)
    private static let legacyTurbo = TranscriptionModel.find(id: "mlx-community/whisper-large-v3-turbo")
    private static let legacyMedium = TranscriptionModel.find(id: "mlx-community/whisper-medium-mlx")

    private static func makeOptions(
        fileExtension: String = "mp3",
        currentChoice: TranscriptionBackendChoice = apiChoice,
        fileSizeBytes: Int64? = nil,
        hasAPIKey: Bool = true,
        hasNativeLocalWhisperModel: Bool = true,
        legacyLocalWhisperModels: [TranscriptionModel] = []
    ) -> AudioImportOptions {
        AudioImportOptions(
            fileExtension: fileExtension,
            currentChoice: currentChoice,
            apiStandardModelID: "whisper-large-v3",
            fileSizeBytes: fileSizeBytes,
            hasAPIKey: hasAPIKey,
            hasNativeLocalWhisperModel: hasNativeLocalWhisperModel,
            legacyLocalWhisperModels: legacyLocalWhisperModels
        )
    }

    private static func testAPIStandardSupportsBroadImportExtensions() {
        let options = makeOptions(fileExtension: "webm")

        assert(options.defaultChoice == apiChoice)
        assert(options.supportedChoices.contains(apiChoice))
        assert(!options.supportedChoices.contains { $0.mode == .apiRealtime })
        assert(!options.supportedChoices.contains { $0.mode == .localAppleLive })
    }

    private static func testAPIRealtimeFallsBackToAPIStandardForImport() {
        let options = makeOptions(
            currentChoice: .apiRealtime(modelID: nil),
            legacyLocalWhisperModels: [legacyTurbo]
        )

        assert(options.defaultChoice == apiChoice)
    }

    private static func testNativeCurrentChoiceDefaultsToNativeWhisper() {
        let options = makeOptions(currentChoice: nativeChoice)

        assert(options.defaultChoice == nativeChoice)
        assert(options.supportedChoices.contains(nativeChoice))
    }

    private static func testLegacyCurrentChoiceDefaultsToSameLegacyModel() {
        let legacyChoice = TranscriptionBackendChoice.legacyMlxWhisper(model: legacyMedium)
        let options = makeOptions(
            currentChoice: legacyChoice,
            legacyLocalWhisperModels: [legacyTurbo, legacyMedium]
        )

        assert(options.defaultChoice == legacyChoice)
    }

    private static func testAPIKeyMissingFallsBackToLocalWhisper() {
        let options = makeOptions(
            currentChoice: apiChoice,
            hasAPIKey: false,
            hasNativeLocalWhisperModel: true
        )

        assert(!options.supportedChoices.contains(apiChoice))
        assert(options.defaultChoice == nativeChoice)
    }

    private static func testNoAvailableBackendReturnsNoDefault() {
        let options = makeOptions(
            hasAPIKey: false,
            hasNativeLocalWhisperModel: false,
            legacyLocalWhisperModels: []
        )

        assert(options.supportedChoices.isEmpty)
        assert(options.defaultChoice == nil)
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
        let options = makeOptions(
            fileSizeBytes: AudioImportOptions.apiUploadLimitBytes + 1,
            hasNativeLocalWhisperModel: true
        )

        assert(!options.supportedChoices.contains(apiChoice))
        assert(options.defaultChoice == nativeChoice)
        assert(options.displayRows.first { $0.choice == apiChoice }?.unavailableReason == "API transcription is unavailable for files over 25MB")
    }

    private static func testLocalWhisperStillEnabledAboveTwentyFiveMegabytes() {
        let options = makeOptions(
            currentChoice: nativeChoice,
            fileSizeBytes: AudioImportOptions.apiUploadLimitBytes + 1,
            hasNativeLocalWhisperModel: true
        )

        assert(options.supportedChoices.contains(nativeChoice))
    }

    private static func testWebMDisablesNativeButAllowsInstalledLegacyImport() {
        let legacyChoice = TranscriptionBackendChoice.legacyMlxWhisper(model: legacyTurbo)
        let options = makeOptions(
            fileExtension: "webm",
            currentChoice: nativeChoice,
            hasAPIKey: false,
            hasNativeLocalWhisperModel: true,
            legacyLocalWhisperModels: [legacyTurbo]
        )

        assert(!options.supportedChoices.contains(nativeChoice))
        assert(options.supportedChoices.contains(legacyChoice))
        assert(options.defaultChoice == legacyChoice)
        assert(options.displayRows.first { $0.choice == nativeChoice }?.unavailableReason == "Native Whisper supports MP3, MP4, M4A, MPEG, MPGA, and WAV imports")
    }

    private static func testNativeAndLegacyRowsAreShownTogether() {
        let options = makeOptions(
            hasNativeLocalWhisperModel: true,
            legacyLocalWhisperModels: [legacyTurbo, legacyMedium]
        )

        assert(options.displayRows.contains { $0.choice == nativeChoice })
        assert(options.displayRows.contains { $0.choice == .legacyMlxWhisper(model: legacyTurbo) })
        assert(options.displayRows.contains { $0.choice == .legacyMlxWhisper(model: legacyMedium) })
    }
}
