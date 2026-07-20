import Foundation

@main
struct NativeWhisperBuildContractTests {
    static func main() throws {
        let buildScriptPath = "BuildSupport/WhisperRuntime/build-whisper.cpp.sh"
        let verifierPath = "BuildSupport/WhisperRuntime/verify-whisper-helper.sh"
        let makefilePath = "Makefile"

        let buildScript = try String(
            contentsOfFile: buildScriptPath,
            encoding: .utf8
        )
        try expect(
            FileManager.default.fileExists(atPath: verifierPath),
            "native whisper helper verifier exists"
        )
        let verifier = try String(
            contentsOfFile: verifierPath,
            encoding: .utf8
        )
        let makefile = try String(
            contentsOfFile: makefilePath,
            encoding: .utf8
        )

        try expect(
            buildScript.contains("-DGGML_METAL=ON"),
            "build explicitly enables Metal"
        )
        try expect(
            buildScript.contains("-DGGML_METAL_EMBED_LIBRARY=ON"),
            "build explicitly embeds Metal kernels"
        )
        try expect(
            buildScript.contains(
                #"verify_script="$(cd "$(dirname "$0")" && pwd)/verify-whisper-helper.sh""#
            ),
            "build resolves the shared verifier"
        )
        try expect(
            buildScript.contains(#""$verify_script" "$helper" "$arch""#),
            "build invokes the shared verifier"
        )
        try expect(
            !buildScript.contains("otool -L \"$helper\" | grep"),
            "build script no longer duplicates verifier implementation"
        )

        for marker in [
            "lipo -archs",
            "otool -arch",
            "Metal.framework",
            "MetalKit.framework",
            "lib(whisper|ggml)",
            "nm -arch",
            "ggml_metallib_start",
            "ggml_metallib_end"
        ] {
            try expect(
                verifier.contains(marker),
                "verifier contains contract marker: \(marker)"
            )
        }

        try expect(
            makefile.contains(
                "WHISPER_VERIFY_SCRIPT = BuildSupport/WhisperRuntime/verify-whisper-helper.sh"
            ),
            "Makefile names the shared verifier"
        )
        try expect(
            makefile.contains(
                "$(WHISPER_STAMP): BuildSupport/WhisperRuntime/build-whisper.cpp.sh $(WHISPER_VERIFY_SCRIPT) $(WHISPER_BUILD_SETTINGS)"
            ),
            "verifier changes invalidate the helper stamp"
        )
        try expect(
            makefile.contains("native-whisper-helper-test: $(WHISPER_STAMP)"),
            "Makefile exposes actual helper validation"
        )
        try expect(
            makefile.contains(
                "$(WHISPER_VERIFY_SCRIPT) \"$$helper\" \"$(ARCH)\""
            ),
            "Make target invokes the shared verifier"
        )

        try verifierAcceptsUniversalMetalHelper(verifierPath: verifierPath)
        try verifierRejectsMissingUniversalSlice(verifierPath: verifierPath)
        try verifierRejectsMissingMetalKit(verifierPath: verifierPath)
        try verifierRejectsDynamicGGMLDependency(verifierPath: verifierPath)
        try verifierRejectsMissingEmbeddedKernelBoundary(verifierPath: verifierPath)
        try verifierRejectsEmptyHelper(verifierPath: verifierPath)

        print("NativeWhisperBuildContractTests passed")
    }

    private static func verifierAcceptsUniversalMetalHelper(
        verifierPath: String
    ) throws {
        let result = try runVerifier(
            verifierPath: verifierPath,
            expectedArch: "universal",
            archs: "x86_64 arm64",
            linkedLibraries: metalLibraries,
            symbols: embeddedSymbols
        )
        try expect(result.status == 0, "valid universal Metal helper passes")
    }

    private static func verifierRejectsMissingUniversalSlice(
        verifierPath: String
    ) throws {
        let result = try runVerifier(
            verifierPath: verifierPath,
            expectedArch: "universal",
            archs: "arm64",
            linkedLibraries: metalLibraries,
            symbols: embeddedSymbols
        )
        try expect(result.status != 0, "missing x86_64 slice fails")
        try expect(
            result.stderr.contains("missing required architecture x86_64"),
            "missing architecture diagnostic"
        )
    }

    private static func verifierRejectsMissingMetalKit(
        verifierPath: String
    ) throws {
        let result = try runVerifier(
            verifierPath: verifierPath,
            expectedArch: "arm64",
            archs: "arm64",
            linkedLibraries: metalLibraries.replacingOccurrences(
                of: metalKitLine,
                with: ""
            ),
            symbols: embeddedSymbols
        )
        try expect(result.status != 0, "missing MetalKit fails")
        try expect(
            result.stderr.contains("missing MetalKit.framework linkage for arm64"),
            "missing MetalKit diagnostic"
        )
    }

    private static func verifierRejectsDynamicGGMLDependency(
        verifierPath: String
    ) throws {
        let result = try runVerifier(
            verifierPath: verifierPath,
            expectedArch: "arm64",
            archs: "arm64",
            linkedLibraries: metalLibraries
                + "\t@rpath/libggml.dylib (compatibility version 0.0.0)\n",
            symbols: embeddedSymbols
        )
        try expect(result.status != 0, "dynamic ggml dependency fails")
        try expect(
            result.stderr.contains("links dynamic whisper.cpp/ggml libraries"),
            "dynamic dependency diagnostic"
        )
    }

    private static func verifierRejectsMissingEmbeddedKernelBoundary(
        verifierPath: String
    ) throws {
        let result = try runVerifier(
            verifierPath: verifierPath,
            expectedArch: "arm64",
            archs: "arm64",
            linkedLibraries: metalLibraries,
            symbols: "000000 T _ggml_metallib_start\n"
        )
        try expect(result.status != 0, "missing kernel end symbol fails")
        try expect(
            result.stderr.contains("missing embedded Metal kernel symbol ggml_metallib_end for arm64"),
            "missing kernel diagnostic"
        )
    }

    private static func verifierRejectsEmptyHelper(
        verifierPath: String
    ) throws {
        let result = try runVerifier(
            verifierPath: verifierPath,
            expectedArch: "arm64",
            archs: "arm64",
            linkedLibraries: metalLibraries,
            symbols: embeddedSymbols,
            helperData: Data()
        )
        try expect(result.status != 0, "empty helper fails")
        try expect(
            result.stderr.contains("helper is empty"),
            "empty helper diagnostic"
        )
    }

    private static func runVerifier(
        verifierPath: String,
        expectedArch: String,
        archs: String,
        linkedLibraries: String,
        symbols: String,
        helperData: Data = Data([0x01])
    ) throws -> ProcessResult {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bin,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let helper = root.appendingPathComponent("whisper-cli")
        FileManager.default.createFile(
            atPath: helper.path,
            contents: helperData
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: helper.path
        )

        let librariesFile = root.appendingPathComponent("libraries.txt")
        let symbolsFile = root.appendingPathComponent("symbols.txt")
        try linkedLibraries.write(
            to: librariesFile,
            atomically: true,
            encoding: .utf8
        )
        try symbols.write(
            to: symbolsFile,
            atomically: true,
            encoding: .utf8
        )

        try writeTool(
            named: "lipo",
            in: bin,
            body: "printf '%s\\n' \"$FAKE_ARCHS\""
        )
        try writeTool(
            named: "otool",
            in: bin,
            body: "cat \"$FAKE_LIBRARIES_FILE\""
        )
        try writeTool(
            named: "nm",
            in: bin,
            body: "cat \"$FAKE_SYMBOLS_FILE\""
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [verifierPath, helper.path, expectedArch]
        process.environment = [
            "PATH": "\(bin.path):/usr/bin:/bin",
            "FAKE_ARCHS": archs,
            "FAKE_LIBRARIES_FILE": librariesFile.path,
            "FAKE_SYMBOLS_FILE": symbolsFile.path
        ]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        return ProcessResult(
            status: process.terminationStatus,
            stdout: String(
                data: try stdout.fileHandleForReading.readToEnd() ?? Data(),
                encoding: .utf8
            ) ?? "",
            stderr: String(
                data: try stderr.fileHandleForReading.readToEnd() ?? Data(),
                encoding: .utf8
            ) ?? ""
        )
    }

    private static func writeTool(
        named name: String,
        in directory: URL,
        body: String
    ) throws {
        let url = directory.appendingPathComponent(name)
        try "#!/bin/sh\nset -eu\n\(body)\n".write(
            to: url,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }

    private static let metalLine =
        "\t/System/Library/Frameworks/Metal.framework/Versions/A/Metal\n"
    private static let metalKitLine =
        "\t/System/Library/Frameworks/MetalKit.framework/Versions/A/MetalKit\n"
    private static let metalLibraries = metalLine + metalKitLine
    private static let embeddedSymbols = """
    000000 T _ggml_metallib_start
    000001 T _ggml_metallib_end
    """

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ label: String
    ) throws {
        guard condition() else { throw TestFailure(label) }
    }
}

private struct ProcessResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
