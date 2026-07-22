import Foundation

#if !QUILL_GROUPED_TEST_RUNNER
@main
#endif
struct AppStateAIProcessingBackendTests {
    static func main() async throws {
        await testLegacyModelsMigrateToIndependentCloudChoices()
        await testCorruptedChoicesFallbackAndPersistNormalizedCloudChoices()
        await testWhitespaceCloudIDsFallbackToRememberedOrDefaultModels()
        await testStoredCloudChoicesReconcileRememberedModels()
        await testStoredLocalChoicesPreserveRememberedCloudModels()
        await testChangingCloudModelWhileLocalPreservesLocalChoice()
        await testDirectCloudChoiceSynchronizesRememberedModel()
        await testPostProcessingAndContextChoicesStayIndependent()
        try testEveryPostProcessingConstructionUsesCentralFactory()
        try testCloudResumeCapturesPostProcessingServiceBeforeTaskStarts()
        try testContextCaptureUsesServiceSnapshotAndKeepsCancellationGuards()
        try testContextModelObserverRebuildsOnlyThroughChoiceChanges()
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

    private static func testCorruptedChoicesFallbackAndPersistNormalizedCloudChoices() async {
        resetAIProcessingDefaults()
        let defaults = UserDefaults.standard
        defaults.set("legacy/post", forKey: "post_processing_model")
        defaults.set("legacy/context", forKey: "context_model")
        defaults.set(Data([0xFF]), forKey: "post_processing_backend_choice")
        defaults.set(Data([0xFF]), forKey: "context_backend_choice")

        let appState = await MainActor.run { AppState() }

        await MainActor.run {
            assert(appState.postProcessingBackendChoice == .cloud(modelID: "legacy/post"))
            assert(appState.contextBackendChoice == .cloud(modelID: "legacy/context"))
            assert(appState.postProcessingModel == "legacy/post")
            assert(appState.contextModel == "legacy/context")
        }
        assert(storedChoice(forKey: "post_processing_backend_choice") == .cloud(modelID: "legacy/post"))
        assert(storedChoice(forKey: "context_backend_choice") == .cloud(modelID: "legacy/context"))
    }

    private static func testWhitespaceCloudIDsFallbackToRememberedOrDefaultModels() async {
        resetAIProcessingDefaults()
        let defaults = UserDefaults.standard
        defaults.set("  legacy/post  ", forKey: "post_processing_model")
        defaults.set("   ", forKey: "context_model")
        storeChoice(.cloud(modelID: " \n "), forKey: "post_processing_backend_choice")
        storeChoice(.cloud(modelID: "\t"), forKey: "context_backend_choice")

        let appState = await MainActor.run { AppState() }

        await MainActor.run {
            assert(appState.postProcessingBackendChoice == .cloud(modelID: "legacy/post"))
            assert(appState.contextBackendChoice == .cloud(modelID: AppState.defaultContextModel))
            assert(appState.postProcessingModel == "legacy/post")
            assert(appState.contextModel == AppState.defaultContextModel)
        }
        assert(defaults.string(forKey: "post_processing_model") == "legacy/post")
        assert(defaults.string(forKey: "context_model") == AppState.defaultContextModel)
        assert(storedChoice(forKey: "post_processing_backend_choice") == .cloud(modelID: "legacy/post"))
        assert(storedChoice(forKey: "context_backend_choice") == .cloud(modelID: AppState.defaultContextModel))
    }

    private static func testStoredCloudChoicesReconcileRememberedModels() async {
        resetAIProcessingDefaults()
        let defaults = UserDefaults.standard
        defaults.set("legacy/post", forKey: "post_processing_model")
        defaults.set("legacy/context", forKey: "context_model")
        storeChoice(.cloud(modelID: "  stored/post  "), forKey: "post_processing_backend_choice")
        storeChoice(.cloud(modelID: "  stored/context  "), forKey: "context_backend_choice")

        let appState = await MainActor.run { AppState() }

        await MainActor.run {
            assert(appState.postProcessingBackendChoice == .cloud(modelID: "stored/post"))
            assert(appState.contextBackendChoice == .cloud(modelID: "stored/context"))
            assert(appState.postProcessingModel == "stored/post")
            assert(appState.contextModel == "stored/context")
        }
        assert(defaults.string(forKey: "post_processing_model") == "stored/post")
        assert(defaults.string(forKey: "context_model") == "stored/context")
        assert(storedChoice(forKey: "post_processing_backend_choice") == .cloud(modelID: "stored/post"))
        assert(storedChoice(forKey: "context_backend_choice") == .cloud(modelID: "stored/context"))
    }

    private static func testStoredLocalChoicesPreserveRememberedCloudModels() async {
        resetAIProcessingDefaults()
        let defaults = UserDefaults.standard
        defaults.set("remembered/post", forKey: "post_processing_model")
        defaults.set("remembered/context", forKey: "context_model")
        let postChoice = AIProcessingBackendChoice.localAI(
            modelID: LocalAIModelCatalog.fast.id
        )
        let contextChoice = AIProcessingBackendChoice.localAI(
            modelID: LocalAIModelCatalog.quality.id
        )
        storeChoice(postChoice, forKey: "post_processing_backend_choice")
        storeChoice(contextChoice, forKey: "context_backend_choice")

        let appState = await MainActor.run { AppState() }

        await MainActor.run {
            assert(appState.postProcessingBackendChoice == postChoice)
            assert(appState.contextBackendChoice == contextChoice)
            assert(appState.postProcessingModel == "remembered/post")
            assert(appState.contextModel == "remembered/context")
        }
        assert(defaults.string(forKey: "post_processing_model") == "remembered/post")
        assert(defaults.string(forKey: "context_model") == "remembered/context")
    }

    private static func testChangingCloudModelWhileLocalPreservesLocalChoice() async {
        resetAIProcessingDefaults()
        let appState = await MainActor.run { AppState() }
        await MainActor.run {
            appState.postProcessingBackendChoice = .localAI(
                modelID: LocalAIModelCatalog.fast.id
            )
            appState.contextBackendChoice = .localAI(
                modelID: LocalAIModelCatalog.quality.id
            )
            appState.postProcessingModel = "new/cloud-model"
            appState.contextModel = "new/context-cloud-model"
            assert(
                appState.postProcessingBackendChoice
                    == .localAI(modelID: LocalAIModelCatalog.fast.id)
            )
            assert(
                appState.contextBackendChoice
                    == .localAI(modelID: LocalAIModelCatalog.quality.id)
            )
        }
    }

    private static func testDirectCloudChoiceSynchronizesRememberedModel() async {
        resetAIProcessingDefaults()
        let appState = await MainActor.run { AppState() }
        await MainActor.run {
            appState.postProcessingBackendChoice = .cloud(modelID: "direct/post")
            appState.contextBackendChoice = .cloud(modelID: "direct/context")
            assert(appState.postProcessingModel == "direct/post")
            assert(appState.contextModel == "direct/context")
            assert(appState.postProcessingBackendChoice == .cloud(modelID: "direct/post"))
            assert(appState.contextBackendChoice == .cloud(modelID: "direct/context"))
        }
        assert(UserDefaults.standard.string(forKey: "post_processing_model") == "direct/post")
        assert(UserDefaults.standard.string(forKey: "context_model") == "direct/context")
        assert(storedChoice(forKey: "post_processing_backend_choice") == .cloud(modelID: "direct/post"))
        assert(storedChoice(forKey: "context_backend_choice") == .cloud(modelID: "direct/context"))
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
        let source = try appStateSource()
        let factoryBody = sourceBlock(
            in: source,
            from: "static func makePostProcessingService(",
            to: "func makePostProcessingService("
        )
        assert(constructorCount(in: factoryBody) == 1)
        assert(constructorCount(in: source.replacingOccurrences(of: factoryBody, with: "")) == 0)
    }

    private static func testCloudResumeCapturesPostProcessingServiceBeforeTaskStarts() throws {
        let body = sourceBlock(
            in: try appStateSource(),
            from: "private func resumeCloudTranscriptionAfterLaunch(",
            to: "private func installCloudTranscriptionTask("
        )
        let snapshot = requiredRange(
            of: "let postProcessingService = makePostProcessingService()",
            in: body
        )
        let task = requiredRange(of: "let task = Task", in: body)
        assert(snapshot.lowerBound < task.lowerBound)
        let taskBody = String(body[task.lowerBound...])
        assert(!taskBody.contains("makePostProcessingService()"))
        assert(taskBody.contains("postProcessingService: postProcessingService"))
    }

    private static func testContextCaptureUsesServiceSnapshotAndKeepsCancellationGuards() throws {
        let body = sourceBlock(
            in: try appStateSource(),
            from: "private func startContextCapture()",
            to: "private func fallbackContextAtStop()"
        )
        let snapshot = requiredRange(of: "let contextService = contextService", in: body)
        let task = requiredRange(of: "contextCaptureTask = Task", in: body)
        assert(snapshot.lowerBound < task.lowerBound)
        let taskBody = String(body[task.lowerBound...])
        assert(taskBody.contains("let context = await contextService.collectContext()"))
        assert(!taskBody.contains("self.contextService.collectContext()"))
        assert(taskBody.contains("guard !Task.isCancelled else { return nil }"))
        assert(taskBody.contains("guard !Task.isCancelled else { return }"))
    }

    private static func testContextModelObserverRebuildsOnlyThroughChoiceChanges() throws {
        let source = try appStateSource()
        let modelObserver = sourceBlock(
            in: source,
            from: "@Published var contextModel: String",
            to: "@Published var holdShortcut: ShortcutBinding"
        )
        assert(!modelObserver.contains("rebuildContextService()"))
        assert(modelObserver.contains("derivedChoice != contextBackendChoice"))

        let choiceObserver = sourceBlock(
            in: source,
            from: "@Published var contextBackendChoice: AIProcessingBackendChoice",
            to: "private var contextService: AppContextService"
        )
        assert(choiceObserver.components(separatedBy: "rebuildContextService()").count - 1 == 1)
    }

    private static func appStateSource() throws -> String {
        try String(contentsOfFile: "Sources/AppState.swift", encoding: .utf8)
    }

    private static func constructorCount(in source: String) -> Int {
        let pattern = #"(?<![A-Za-z0-9_])PostProcessingService\("#
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return regex.numberOfMatches(in: source, range: range)
    }

    private static func sourceBlock(
        in source: String,
        from startMarker: String,
        to endMarker: String
    ) -> String {
        guard let start = source.range(of: startMarker),
              let end = source.range(
                  of: endMarker,
                  range: start.upperBound..<source.endIndex
              ) else {
            preconditionFailure("Expected source block from \(startMarker) to \(endMarker)")
        }
        return String(source[start.lowerBound..<end.lowerBound])
    }

    private static func requiredRange(
        of text: String,
        in source: String
    ) -> Range<String.Index> {
        guard let range = source.range(of: text) else {
            preconditionFailure("Expected source to contain \(text)")
        }
        return range
    }

    private static func storeChoice(
        _ choice: AIProcessingBackendChoice,
        forKey key: String
    ) {
        AIProcessingBackendChoiceStore.save(
            choice,
            defaults: .standard,
            key: key
        )
    }

    private static func storedChoice(forKey key: String) -> AIProcessingBackendChoice? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(AIProcessingBackendChoice.self, from: data)
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
