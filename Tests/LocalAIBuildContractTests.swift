import Foundation

@main
struct LocalAIBuildContractTests {
    static func main() throws {
        let buildScriptPath = "BuildSupport/LlamaRuntime/build-llama.cpp.sh"
        let verifierPath = "BuildSupport/LlamaRuntime/verify-llama-server.sh"
        let makefilePath = "Makefile"
        let contextServicePath = "Sources/AppContextService.swift"

        let buildScript = try String(contentsOfFile: buildScriptPath, encoding: .utf8)
        try expect(
            FileManager.default.fileExists(atPath: verifierPath),
            "local AI server verifier exists"
        )
        let verifier = try String(contentsOfFile: verifierPath, encoding: .utf8)
        let makefile = try String(contentsOfFile: makefilePath, encoding: .utf8)
        let contextService = try String(contentsOfFile: contextServicePath, encoding: .utf8)

        try expect(buildScript.contains("-DGGML_METAL=ON"), "build explicitly enables Metal")
        try expect(buildScript.contains("-DGGML_METAL_EMBED_LIBRARY=ON"), "build explicitly embeds Metal kernels")
        try expect(buildScript.contains("-DGGML_NATIVE=OFF"), "build disables host-native CPU tuning for distribution")
        try expect(makefile.contains("LLAMA_CPP_VERSION ?= b11046"), "llama.cpp is pinned to the Gemma 4 capable release")
        try expect(buildScript.contains("-DLLAMA_OPENSSL=OFF"), "build does not link OpenSSL from the build machine")
        try expect(buildScript.contains("-DBUILD_SHARED_LIBS=OFF"), "build links llama.cpp statically")
        try expect(buildScript.contains("-DCMAKE_OSX_DEPLOYMENT_TARGET=13.0"), "helper runs on the app's minimum macOS")
        try expect(buildScript.contains("lipo -create"), "universal helper combines per-architecture builds so each keeps its CPU kernels")
        try expect(!buildScript.contains(#"-DCMAKE_OSX_ARCHITECTURES="arm64;x86_64""#), "no single multi-architecture ggml build (falls back to generic CPU code)")
        try expect(verifier.contains("minos"), "verifier checks the helper's minimum macOS")
        try expect(buildScript.contains("-DBUILD_SHARED_LIBS=OFF"), "build links llama/ggml statically")
        try expect(buildScript.contains("-DLLAMA_BUILD_EXAMPLES=ON"), "build enables the examples tree containing llama-server")
        try expect(buildScript.contains("-DLLAMA_BUILD_SERVER=ON"), "build enables the llama-server tool subdirectory")
        try expect(
            buildScript.contains(#"verify_script="$(cd "$(dirname "$0")" && pwd)/verify-llama-server.sh""#),
            "build resolves the shared verifier"
        )
        try expect(buildScript.contains(#""$verify_script" "$helper" "$arch""#), "build invokes the shared verifier")
        try expect(buildScript.contains("--target llama-server"), "build targets llama-server")
        try expect(
            buildScript.contains(#"license="$checkout_dir/LICENSE""#),
            "build resolves the exact pinned checkout LICENSE"
        )
        try expect(
            buildScript.contains(#"if [ ! -s "$license" ]; then"#),
            "build fails when the pinned checkout LICENSE is missing or empty"
        )

        for marker in [
            "lipo -archs",
            "otool -arch",
            "Metal.framework",
            "MetalKit.framework",
            "lib(llama|ggml)",
            "nm -arch",
            "ggml_metallib(_[a-z0-9_]+)?_start",
            "ggml_metallib(_[a-z0-9_]+)?_end",
            "non-system library"
        ] {
            try expect(verifier.contains(marker), "verifier contains contract marker: \(marker)")
        }

        try expect(
            makefile.contains("LLAMA_VERIFY_SCRIPT = BuildSupport/LlamaRuntime/verify-llama-server.sh"),
            "Makefile names the shared verifier"
        )
        try expect(
            makefile.contains(
                "$(LLAMA_STAMP): BuildSupport/LlamaRuntime/build-llama.cpp.sh $(LLAMA_VERIFY_SCRIPT) $(LLAMA_BUILD_SETTINGS)"
            ),
            "verifier changes invalidate the helper stamp"
        )
        try expect(makefile.contains("llama-server-helper-test: $(LLAMA_STAMP)"), "Makefile exposes actual helper validation")
        try expect(
            makefile.contains("$(LLAMA_VERIFY_SCRIPT) \"$$helper\" \"$(ARCH)\""),
            "Make target invokes the shared verifier"
        )
        try expect(
            makefile.contains(
                "$(APP_EXECUTABLE_TARGET): $(SOURCES) Info.plist $(ICON_ICNS) $(BUILD_SETTINGS) $(SPARKLE_STAMP) $(WHISPER_STAMP) $(LLAMA_STAMP) $(LOCALIZATION_STAMP)"
            ),
            "app target depends on the llama helper stamp"
        )
        try expect(
            makefile.contains(#"cp "$$llama_helper" "$(RESOURCES)/llama/llama-server""#)
                && makefile.contains(#"chmod 755 "$(RESOURCES)/llama/llama-server""#),
            "Makefile copies the llama helper and makes it executable"
        )
        try expect(
            makefile.contains(#"llama_license="$(LLAMA_CPP_DIR)/LICENSE""#)
                && makefile.contains(#"if [ ! -s "$$llama_license" ]; then"#)
                && makefile.contains(#"cp "$$llama_license" "$(RESOURCES)/llama/LICENSE""#)
                && makefile.contains(#"test -s "$(RESOURCES)/llama/LICENSE""#),
            "Makefile validates and copies the pinned checkout LICENSE into the app bundle"
        )
        try expect(
            makefile.contains(
                #"llama_helper="$(BUILD_DIR)/codesign-staging/$(APP_NAME).app/Contents/Resources/llama/llama-server""#
            )
                && makefile.contains(
                    #"codesign --force --options runtime --sign "$(CODESIGN_IDENTITY)" "$$llama_helper""#
                ),
            "staged llama-server receives its own runtime codesign invocation"
        )
        try expect(
            makefile.contains("test-local-ai-integration: $(TEST_BUILD_DIR)/LocalAIIntegrationTests")
                && makefile.contains("--ctx-size 16384")
                && makefile.contains("LOCAL_AI_INTEGRATION_SHARD_ONE_SHA256")
                && makefile.contains("LOCAL_AI_INTEGRATION_SHARD_TWO_SHA256")
                && makefile.contains("[skip] Local AI integration prerequisite unavailable"),
            "Makefile exposes a checksum-verified opt-in loopback integration target"
        )
        try expect(
            makefile.contains("test-local-ai-integration > \"$$plan_file\"")
                && makefile.contains("Tests/LocalAIIntegrationTests.swift"),
            "test wiring plans the opt-in integration executable exactly once"
        )
        try expect(
            contextService.contains("if endpoint.supportsImages")
                && contextService.contains("\"type\": \"image_url\"")
                && contextService.contains("\"image_url\": [\"url\": screenshotDataURL]")
                && contextService.contains("\"text\": metadata"),
            "Context keeps the compatible vision screenshot request shape"
        )

        print("LocalAIBuildContractTests passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ label: String) throws {
        guard condition() else { throw TestFailure(label) }
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
