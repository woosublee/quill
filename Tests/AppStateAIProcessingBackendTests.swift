import Foundation

#if !QUILL_GROUPED_TEST_RUNNER
@main
#endif
struct AppStateAIProcessingBackendTests {
    static func main() async throws {
        await testLegacyModelsMigrateToIndependentCloudChoices()
        await testChangingCloudModelWhileLocalPreservesLocalChoice()
        await testPostProcessingAndContextChoicesStayIndependent()
        try testEveryPostProcessingConstructionUsesCentralFactory()
        print("AppStateAIProcessingBackendTests passed")
    }

    private static func testLegacyModelsMigrateToIndependentCloudChoices() async {
        resetAIProcessingDefaults()
        UserDefaults.standard.set("custom/post", forKey: "post_processing_model")
        UserDefaults.standard.set("custom/context", forKey: "context_model")
        let appState = await MainActor.run { AppState() }
        await MainActor.run {
            assert(appState.postProcessingBackendChoice == .cloud(modelID: "custom/post"))
            assert(appState.contextBackendChoice == .cloud(modelID: "custom/context"))
        }
    }

    private static func testChangingCloudModelWhileLocalPreservesLocalChoice() async {
        resetAIProcessingDefaults()
        let appState = await MainActor.run { AppState() }
        await MainActor.run {
            appState.postProcessingBackendChoice = .localAI(
                modelID: LocalAIModelCatalog.fast.id
            )
            appState.postProcessingModel = "new/cloud-model"
            assert(
                appState.postProcessingBackendChoice
                    == .localAI(modelID: LocalAIModelCatalog.fast.id)
            )
        }
    }

    private static func testPostProcessingAndContextChoicesStayIndependent() async {
        resetAIProcessingDefaults()
        let appState = await MainActor.run { AppState() }
        await MainActor.run {
            appState.postProcessingBackendChoice = .localAI(
                modelID: LocalAIModelCatalog.fast.id
            )
            appState.contextBackendChoice = .cloud(modelID: "context/cloud")
            assert(appState.postProcessingBackendChoice.isLocal)
            assert(appState.contextBackendChoice == .cloud(modelID: "context/cloud"))
        }
    }

    private static func testEveryPostProcessingConstructionUsesCentralFactory() throws {
        let source = try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)
        let constructorPattern = #"(?<![A-Za-z0-9_])PostProcessingService\("#
        let constructorRegex = try NSRegularExpression(pattern: constructorPattern)
        let sourceRange = NSRange(source.startIndex..<source.endIndex, in: source)
        assert(constructorRegex.numberOfMatches(in: source, range: sourceRange) == 1)
        assert(source.contains("func makePostProcessingService("))
    }

    private static func resetAIProcessingDefaults() {
        for key in [
            "post_processing_model",
            "context_model",
            "post_processing_backend_choice",
            "context_backend_choice"
        ] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
