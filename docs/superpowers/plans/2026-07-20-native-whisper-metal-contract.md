# Native Whisper Metal Contract Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Quill's existing whisper.cpp Metal acceleration an explicit, build-breaking artifact contract and preserve the current GPU-enabled runtime invocation.

**Architecture:** Keep the existing whisper.cpp v1.9.1 subprocess architecture and embedded Metal kernel mode. Add a shared shell verifier that the build script and a focused Make target both invoke, then lock the build and runtime contracts with fast Swift tests that do not rebuild whisper.cpp during `make test`.

**Tech Stack:** Bash, CMake, Make, Swift 5.10 executable tests, whisper.cpp v1.9.1, macOS `lipo`/`otool`/`nm`/`codesign`, Metal and MetalKit.

## Global Constraints

- Work only in the existing harness-owned worktree on branch `issue-184-whisper-metal-contract`; do not create or remove another worktree.
- Use test-driven development for production changes: write the failing contract test, run it, implement the minimum change, and run it again.
- Keep whisper.cpp pinned to `v1.9.1`.
- Keep `BUILD_SHARED_LIBS=OFF`, `WHISPER_BUILD_TESTS=OFF`, and `WHISPER_BUILD_EXAMPLES=ON`.
- Explicitly build with `GGML_METAL=ON` and `GGML_METAL_EMBED_LIBRARY=ON`.
- Keep the universal release helper as `arm64;x86_64`; do not remove Intel support.
- Do not bundle a separate `default.metallib` while embedded kernel mode is selected.
- Do not add `GGML_METAL_PATH_RESOURCES`, `-ngl`, a user-facing Metal toggle, or automatic GPU-to-CPU retry.
- Do not change Native Whisper model metadata, installer behavior, Settings UI, Legacy mlx-whisper, cloud transcription, or post-processing.
- Never modify or overwrite `/Applications/Quill.app`; build and inspect only `build/Quill Dev.app` with bundle ID `com.woosublee.quill.dev`.
- Never put signing identity details, credentials, API keys, or OAuth values in source, tests, logs, docs, commits, issues, or PR text.
- Try `CODESIGN_IDENTITY=Quill` for the authorized final build. If Keychain returns `errSecInternalComponent`, report that exact limitation and use `CODESIGN_IDENTITY=-` only as an additional compile/bundle verification, not as evidence that the configured identity succeeded.
- Do not push, open a PR, merge, close #184, or edit Roadmap #176 until explicitly requested after implementation verification.

---

## File structure

- Create `BuildSupport/WhisperRuntime/verify-whisper-helper.sh`: the single executable artifact verifier shared by the helper build and focused Make target.
- Modify `BuildSupport/WhisperRuntime/build-whisper.cpp.sh`: explicitly request Metal and embedded kernels, then delegate all helper artifact checks to the shared verifier.
- Modify `Makefile`: invalidate the whisper stamp when the verifier changes, expose `native-whisper-helper-test`, and wire the fast contract test into `make test`.
- Create `Tests/NativeWhisperBuildContractTests.swift`: verify source wiring and exercise the verifier with controlled fake `lipo`, `otool`, and `nm` commands.
- Modify `Tests/NativeWhisperRuntimeTests.swift`: characterize and lock the existing rule that Quill does not pass no-GPU flags.

---

### Task 1: Add the shared Metal helper verifier and explicit build contract

**Files:**
- Create: `BuildSupport/WhisperRuntime/verify-whisper-helper.sh`
- Modify: `BuildSupport/WhisperRuntime/build-whisper.cpp.sh:18-61`
- Modify: `Makefile:30-31,57,81-84,286-298,306-326`
- Create: `Tests/NativeWhisperBuildContractTests.swift`

**Interfaces:**
- Consumes: `build-whisper.cpp.sh <repo-url> <version> <checkout-dir> <arch>` and the existing `ARCH` values `arm64`, `x86_64`, or `universal`.
- Produces: `verify-whisper-helper.sh <helper-path> <expected-arch>` with exit status 0 only when every requested slice links Metal/MetalKit, embeds the Metal kernel boundaries, and avoids dynamic whisper/ggml libraries.
- Produces: Make target `native-whisper-helper-test`, which validates the helper path stored in `build/.whisper-helper` for the current `ARCH`.

- [ ] **Step 1: Write the failing build-contract and verifier behavior test**

Create `Tests/NativeWhisperBuildContractTests.swift`:

```swift
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
                data: stdout.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "",
            stderr: String(
                data: stderr.fileHandleForReading.readDataToEndOfFile(),
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
```

- [ ] **Step 2: Compile and run the focused test to verify RED**

Run:

```bash
swiftc -parse-as-library \
  Tests/NativeWhisperBuildContractTests.swift \
  -o /tmp/NativeWhisperBuildContractTests
/tmp/NativeWhisperBuildContractTests
```

Expected: FAIL with `native whisper helper verifier exists` because `BuildSupport/WhisperRuntime/verify-whisper-helper.sh` does not exist. If it fails for a Swift syntax error instead, fix only the test and rerun until the missing verifier is the failure.

- [ ] **Step 3: Create the minimal shared verifier**

Create `BuildSupport/WhisperRuntime/verify-whisper-helper.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

helper="${1:?helper path required}"
expected_arch="${2:?expected architecture required}"

fail() {
  printf 'Native Whisper helper verification failed: %s\n' "$1" >&2
  exit 1
}

[ -x "$helper" ] || fail "helper is missing or not executable: $helper"
[ "$(stat -f %z "$helper")" -gt 0 ] || fail "helper is empty: $helper"

helper_archs="$(lipo -archs "$helper")"
case "$expected_arch" in
  universal)
    required_archs=(arm64 x86_64)
    ;;
  arm64|x86_64)
    required_archs=("$expected_arch")
    ;;
  *)
    fail "unsupported expected architecture: $expected_arch"
    ;;
esac

for required_arch in "${required_archs[@]}"; do
  case " $helper_archs " in
    *" $required_arch "*) ;;
    *) fail "missing required architecture $required_arch; found: $helper_archs" ;;
  esac

  linked_libraries="$(otool -arch "$required_arch" -L "$helper")"
  grep -F 'Metal.framework' <<<"$linked_libraries" >/dev/null \
    || fail "missing Metal.framework linkage for $required_arch"
  grep -F 'MetalKit.framework' <<<"$linked_libraries" >/dev/null \
    || fail "missing MetalKit.framework linkage for $required_arch"
  if grep -E '(@rpath/)?lib(whisper|ggml)' <<<"$linked_libraries" >/dev/null; then
    fail "helper links dynamic whisper.cpp/ggml libraries for $required_arch"
  fi

  symbols="$(nm -arch "$required_arch" -gU "$helper")"
  for symbol in ggml_metallib_start ggml_metallib_end; do
    grep -F "$symbol" <<<"$symbols" >/dev/null \
      || fail "missing embedded Metal kernel symbol $symbol for $required_arch"
  done
done

printf 'Verified Native Whisper Metal helper: %s (%s)\n' \
  "$helper" "$helper_archs"
```

Then make it executable:

```bash
chmod 755 BuildSupport/WhisperRuntime/verify-whisper-helper.sh
```

- [ ] **Step 4: Make Metal configuration explicit and delegate artifact checks**

Modify `BuildSupport/WhisperRuntime/build-whisper.cpp.sh`.

After the argument declarations, add:

```bash
verify_script="$(cd "$(dirname "$0")" && pwd)/verify-whisper-helper.sh"
```

Change the CMake invocation to:

```bash
cmake -S "$checkout_dir" -B "$checkout_dir/build" \
  "${cmake_arch_args[@]}" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF \
  -DWHISPER_BUILD_TESTS=OFF \
  -DWHISPER_BUILD_EXAMPLES=ON \
  -DGGML_METAL=ON \
  -DGGML_METAL_EMBED_LIBRARY=ON
```

Replace the current helper existence, `otool`, and `lipo` verification block after `helper=...` with:

```bash
"$verify_script" "$helper" "$arch"
```

Do not retain the old duplicated verification block.

- [ ] **Step 5: Wire the verifier and focused target into Makefile**

Near the existing whisper variables, add:

```make
WHISPER_VERIFY_SCRIPT = BuildSupport/WhisperRuntime/verify-whisper-helper.sh
```

Add `native-whisper-helper-test` to `.PHONY`:

```make
.PHONY: all clean run icon dmg codesign-dmg notarize install reset-permissions install-and-run check-test-wiring test localization-bundle-test native-whisper-helper-test print-app-version print-build-number print-build-tag print-version-metadata FORCE /tmp/LocalizationResourceTests
```

Change the helper stamp prerequisite line to:

```make
$(WHISPER_STAMP): BuildSupport/WhisperRuntime/build-whisper.cpp.sh $(WHISPER_VERIFY_SCRIPT) $(WHISPER_BUILD_SETTINGS)
```

After the stamp recipe, add:

```make
native-whisper-helper-test: $(WHISPER_STAMP)
	@helper="$$(cat "$(WHISPER_STAMP)")"; \
		$(WHISPER_VERIFY_SCRIPT) "$$helper" "$(ARCH)"
```

Wire the new fast test into `make test`, near `ManualReleaseWorkflowTests`:

```make
	@swiftc -parse-as-library Tests/NativeWhisperBuildContractTests.swift -o /tmp/NativeWhisperBuildContractTests
	@/tmp/NativeWhisperBuildContractTests
```

- [ ] **Step 6: Run focused tests and wiring to verify GREEN**

Run:

```bash
swiftc -parse-as-library \
  Tests/NativeWhisperBuildContractTests.swift \
  -o /tmp/NativeWhisperBuildContractTests
/tmp/NativeWhisperBuildContractTests
make check-test-wiring
git diff --check
```

Expected:

```text
NativeWhisperBuildContractTests passed
```

`make check-test-wiring` and `git diff --check` must exit 0.

- [ ] **Step 7: Verify the current arm64 helper with the real verifier**

Run:

```bash
make native-whisper-helper-test ARCH="$(uname -m)"
```

Expected output includes:

```text
Verified Native Whisper Metal helper:
```

On Apple Silicon, the architecture list must include `arm64`. This step may rebuild the helper if its build stamp is stale.

- [ ] **Step 8: Commit the build contract**

Run:

```bash
git add \
  BuildSupport/WhisperRuntime/build-whisper.cpp.sh \
  BuildSupport/WhisperRuntime/verify-whisper-helper.sh \
  Makefile \
  Tests/NativeWhisperBuildContractTests.swift
git commit -m "Enforce Native Whisper Metal artifacts

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: Lock the GPU-enabled runtime invocation

**Files:**
- Modify: `Tests/NativeWhisperRuntimeTests.swift:5-15,58-77`

**Interfaces:**
- Consumes: the existing `NativeWhisperRuntime.transcribe(audioURL:modelURL:languageCode:)` subprocess invocation.
- Produces: a characterization contract proving that Quill preserves `-mc 0` while omitting `-ng`, `--no-gpu`, and `-ngl`.

This is a test-only characterization of behavior already verified in whisper.cpp v1.9.1. It does not require or justify a production runtime change.

- [ ] **Step 1: Rename and strengthen the existing argument-recording test**

In `main()`, replace:

```swift
try await testRuntimeDisablesTextContext()
```

with:

```swift
try await testRuntimeKeepsGPUEnabledAndDisablesTextContext()
```

Rename the function to:

```swift
private static func testRuntimeKeepsGPUEnabledAndDisablesTextContext() async throws {
```

After the existing `-mc 0` assertions, add:

```swift
assert(!args.contains("-ng"), "Expected Native Whisper to keep GPU enabled")
assert(!args.contains("--no-gpu"), "Expected Native Whisper to keep GPU enabled")
assert(!args.contains("-ngl"), "Expected whisper-cli GPU policy, not generic layer offload")
```

- [ ] **Step 2: Run the focused characterization test**

Run:

```bash
swiftc -parse-as-library \
  Sources/LocalizedStringLookup.swift \
  Sources/NativeWhisperModel.swift \
  Sources/NativeWhisperRuntime.swift \
  Tests/NativeWhisperRuntimeTests.swift \
  -o /tmp/NativeWhisperRuntimeTests
/tmp/NativeWhisperRuntimeTests
```

Expected:

```text
NativeWhisperRuntimeTests passed
```

The test is expected to pass immediately because it records an intentional existing runtime contract. If it fails, do not add GPU flags; investigate the actual current arguments before changing production code.

- [ ] **Step 3: Run the build-contract test together with runtime tests**

Run:

```bash
/tmp/NativeWhisperBuildContractTests
/tmp/NativeWhisperRuntimeTests
git diff --check
```

Expected: both test executables pass and `git diff --check` exits 0.

- [ ] **Step 4: Commit the runtime contract test**

Run:

```bash
git add Tests/NativeWhisperRuntimeTests.swift
git commit -m "Lock Native Whisper GPU invocation

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: Verify universal artifacts, app signing, and performance evidence

**Files:**
- Modify only if a focused verification exposes a reproducible contract defect and a failing regression test is added first.
- Do not commit generated helpers, app bundles, DMGs, WAV fixtures, model files, benchmark logs, or credentials.

**Interfaces:**
- Consumes: `native-whisper-helper-test`, `build/Quill Dev.app`, the installed `ggml-large-v3-turbo` model, and the bundled or stamped `whisper-cli`.
- Produces: fresh verification evidence for architecture, Metal initialization, runtime correctness, signing, bundle size, and comparative performance.

- [ ] **Step 1: Run all fast automated tests**

Run:

```bash
make check-test-wiring
make test
git diff --check
```

Expected: every test passes, including:

```text
NativeWhisperBuildContractTests passed
NativeWhisperRuntimeTests passed
```

Known Core Data entity warnings and AVFoundation non-interleaved warnings may still appear; do not treat pre-existing warnings as evidence of a new failure. Any nonzero exit is a blocker.

- [ ] **Step 2: Build and verify the universal helper**

Run:

```bash
make native-whisper-helper-test ARCH=universal
helper="$(cat build/.whisper-helper)"
lipo -archs "$helper"
stat -f 'helper_bytes=%z' "$helper"
```

Expected:

```text
Verified Native Whisper Metal helper:
x86_64 arm64
```

The `lipo` output may list the two architectures in either order. Record the helper size but do not commit it.

- [ ] **Step 3: Build and strictly verify the universal Quill Dev app**

First try the configured development identity:

```bash
make all \
  ARCH=universal \
  APP_NAME="Quill Dev" \
  BUNDLE_ID="com.woosublee.quill.dev" \
  CODESIGN_IDENTITY=Quill
xattr -cr build/
codesign --verify --deep --strict --verbose=2 "build/Quill Dev.app"
```

Expected: build exit 0 and `build/Quill Dev.app: valid on disk`.

If and only if the local Keychain rejects nested Sparkle signing with `errSecInternalComponent`, preserve that output and run this additional compile/bundle check:

```bash
rm -rf build/codesign-staging
rm -f "build/Quill Dev.app/Contents/MacOS/Quill Dev"
make all \
  ARCH=universal \
  APP_NAME="Quill Dev" \
  BUNDLE_ID="com.woosublee.quill.dev" \
  CODESIGN_IDENTITY=-
xattr -cr build/
codesign --verify --deep --strict --verbose=2 "build/Quill Dev.app"
```

Report the configured-identity failure separately. Do not claim the ad hoc result as a successful `Quill` identity build.

Then verify the bundled helper with the same contract:

```bash
BuildSupport/WhisperRuntime/verify-whisper-helper.sh \
  "build/Quill Dev.app/Contents/Resources/whisper/whisper-cli" \
  universal
plutil -extract CFBundleIdentifier raw \
  "build/Quill Dev.app/Contents/Info.plist"
```

Expected bundle ID:

```text
com.woosublee.quill.dev
```

- [ ] **Step 4: Generate a deterministic local benchmark WAV outside the repository**

Run:

```bash
python3 - <<'PY'
import math
import struct
import wave

path = "/tmp/quill-whisper-metal-benchmark.wav"
rate = 16_000
seconds = 30
with wave.open(path, "wb") as output:
    output.setnchannels(1)
    output.setsampwidth(2)
    output.setframerate(rate)
    frames = bytearray()
    for index in range(rate * seconds):
        sample = int(900 * math.sin(2 * math.pi * 220 * index / rate))
        frames += struct.pack("<h", sample)
    output.writeframes(frames)
print(path)
PY
```

Expected: `/tmp/quill-whisper-metal-benchmark.wav` is a 30-second, 16 kHz, mono PCM16 WAV. Never add it to git.

- [ ] **Step 5: Run one warm-up and three measured Metal/CPU runs**

Use the installed Quill Dev model and stamped helper:

```bash
bash <<'SH'
set -euo pipefail

helper="$(cat build/.whisper-helper)"
model="$HOME/Library/Application Support/Quill Dev/LocalWhisper/Models/ggml-large-v3-turbo.bin"
audio="/tmp/quill-whisper-metal-benchmark.wav"
root="/tmp/quill-whisper-metal-benchmark"

test -x "$helper"
test -s "$model"
test -s "$audio"
rm -rf "$root"
mkdir -p "$root"

run_once() {
  local mode="$1"
  local run="$2"
  local no_gpu=()
  if [ "$mode" = cpu ]; then
    no_gpu=(-ng)
  fi
  /usr/bin/time -p "$helper" \
    "${no_gpu[@]}" \
    -m "$model" \
    -f "$audio" \
    -nt \
    -mc 0 \
    -oj \
    -of "$root/${mode}-${run}" \
    >"$root/${mode}-${run}.stdout" \
    2>"$root/${mode}-${run}.stderr"
}

run_once metal warmup
run_once cpu warmup
for run in 1 2 3; do
  run_once metal "$run"
  run_once cpu "$run"
done
SH
```

Expected: all eight runs exit 0 and produce JSON outputs. The Metal stderr must contain device initialization evidence; the CPU run may still enumerate Metal devices during backend registration, so performance and `use gpu`/execution context must be interpreted together rather than using framework loading alone.

- [ ] **Step 6: Summarize median performance and transcript equivalence**

Run:

```bash
python3 - <<'PY'
import json
import pathlib
import statistics

root = pathlib.Path("/tmp/quill-whisper-metal-benchmark")

def real_times(mode):
    values = []
    for run in (1, 2, 3):
        lines = (root / f"{mode}-{run}.stderr").read_text().splitlines()
        values.append(float(next(line.split()[1] for line in lines if line.startswith("real "))))
    return values

def transcript(mode, run):
    value = json.loads((root / f"{mode}-{run}.json").read_text())
    return " ".join(str(value.get("text", "")).split())

metal = real_times("metal")
cpu = real_times("cpu")
metal_median = statistics.median(metal)
cpu_median = statistics.median(cpu)
print(f"metal_runs={metal}")
print(f"cpu_runs={cpu}")
print(f"metal_median={metal_median:.3f}")
print(f"cpu_median={cpu_median:.3f}")
print(f"speedup={cpu_median / metal_median:.2f}x")
print(f"transcripts_equal={transcript('metal', 1) == transcript('cpu', 1)}")
if not metal_median < cpu_median:
    raise SystemExit("Metal median was not faster than CPU median")
PY

rg -n \
  'ggml_metal_init: found device|ggml_metal_init: picking default device|use gpu' \
  /tmp/quill-whisper-metal-benchmark/metal-1.stderr
```

Expected:

- Metal median is lower than CPU median.
- `transcripts_equal=true` for the deterministic fixture.
- The Metal log identifies an Apple GPU and default device selection.
- Record the speedup as machine-specific evidence, not a universal guarantee.

- [ ] **Step 7: Build a Quill Dev DMG and enforce the size ceiling**

Use the same signing result as Step 3. If the configured identity succeeded:

```bash
make dmg \
  ARCH=universal \
  APP_NAME="Quill Dev" \
  BUNDLE_ID="com.woosublee.quill.dev" \
  CODESIGN_IDENTITY=Quill
```

If only the ad hoc verification path was available:

```bash
make dmg \
  ARCH=universal \
  APP_NAME="Quill Dev" \
  BUNDLE_ID="com.woosublee.quill.dev" \
  CODESIGN_IDENTITY=-
```

Then run:

```bash
python3 - <<'PY'
from pathlib import Path
path = Path("build/Quill Dev.dmg")
size = path.stat().st_size
limit = 150 * 1024 * 1024
print(f"dmg_bytes={size}")
print(f"dmg_mib={size / 1024 / 1024:.2f}")
if size > limit:
    raise SystemExit("Quill Dev DMG exceeds 150 MiB")
PY
```

Expected: the model-free DMG remains at or below 150 MiB. Do not add the DMG to git.

- [ ] **Step 8: Review architectural boundaries**

Run:

```bash
changed_files="$(git diff --name-only origin/main...HEAD)"
printf '%s\n' "$changed_files"
```

Confirm the implementation changes are limited to:

```text
BuildSupport/WhisperRuntime/build-whisper.cpp.sh
BuildSupport/WhisperRuntime/verify-whisper-helper.sh
Makefile
Tests/NativeWhisperBuildContractTests.swift
Tests/NativeWhisperRuntimeTests.swift
docs/superpowers/specs/2026-07-20-native-whisper-metal-contract-design.md
docs/superpowers/plans/2026-07-20-native-whisper-metal-contract.md
```

If another file changed, explain why it is required by the approved design or revert it. Confirm there are no changes to `NativeWhisperInstaller`, `NativeWhisperModel`, Settings UI, transcription backend selection, cloud transcription, or `/Applications/Quill.app`.

- [ ] **Step 9: Record evidence and stop before external publication**

Prepare a concise completion report containing:

- focused RED/GREEN evidence,
- `make test` result,
- actual arm64 and universal helper verification,
- configured-identity codesign result and any Keychain limitation,
- ad hoc result if used,
- helper and DMG sizes,
- Metal and CPU medians,
- measured speedup,
- transcript equivalence,
- clean git status,
- commits created.

Do not push, create a PR, merge, edit #184, edit Roadmap #176, or close the issue until the user explicitly requests those actions.
