import Foundation

@main
struct BuildMetadataTests {
    static func main() throws {
        try testMakefileStampsLocalBuildMetadata()
        try testBuildSettingsTrackCodesignIdentity()
        try testMakefileDefinesSeparateSystemAudioRunTarget()
        try testReleaseWorkflowsPassBuildMetadataToMake()
        print("BuildMetadataTests passed")
    }

    private static func testMakefileStampsLocalBuildMetadata() throws {
        let makefile = try String(contentsOfFile: "Makefile", encoding: .utf8)

        assertContains(makefile, "GIT_RELEASE_TAG := $(shell git describe --tags --abbrev=0 --match 'v[0-9]*'")
        assertContains(makefile, "APP_VERSION ?= $(patsubst v%,%,$(if $(GIT_RELEASE_TAG),$(GIT_RELEASE_TAG),v0.0.1))")
        assertContains(makefile, "GIT_COMMIT_COUNT := $(shell git rev-list --count HEAD")
        assertContains(makefile, "BUILD_NUMBER ?= $(if $(GIT_COMMIT_COUNT),$(GIT_COMMIT_COUNT),1)")
        assertContains(makefile, "GIT_SHORT_SHA := $(shell git rev-parse --short HEAD")
        assertContains(makefile, "BUILD_TAG ?= $(if $(GIT_SHORT_SHA),local-$(GIT_SHORT_SHA),local-unknown)")
        assertContains(makefile, "$(APP_VERSION)")
        assertContains(makefile, "$(BUILD_NUMBER)")
        assertContains(makefile, "$(BUILD_TAG)")
        assertContains(makefile, "$(APP_VERSION)\" \"$(BUILD_NUMBER)\" \"$(BUILD_TAG)")
        assertContains(makefile, "plutil -replace CFBundleShortVersionString -string \"$(APP_VERSION)\" \"$(CONTENTS)/Info.plist\"")
        assertContains(makefile, "plutil -replace CFBundleVersion -string \"$(BUILD_NUMBER)\" \"$(CONTENTS)/Info.plist\"")
        assertContains(makefile, "plutil -replace QuillBuildTag -string \"$(BUILD_TAG)\" \"$(CONTENTS)/Info.plist\"")
    }

    private static func testBuildSettingsTrackCodesignIdentity() throws {
        let makefile = try String(contentsOfFile: "Makefile", encoding: .utf8)

        assertContains(makefile, "$(CODESIGN_IDENTITY)")
        assertContains(makefile, "$(BUILD_TAG)\" \"$(GOOGLE_CALENDAR_OAUTH_CLIENT_ID)\" \"$(GOOGLE_CALENDAR_OAUTH_CLIENT_SECRET)\" \"$(CODESIGN_IDENTITY)")
    }

    private static func testMakefileDefinesSeparateSystemAudioRunTarget() throws {
        let makefile = try String(contentsOfFile: "Makefile", encoding: .utf8)

        assertContains(makefile, "SYSTEM_AUDIO_APP_NAME ?= Quill SA")
        assertContains(makefile, "SYSTEM_AUDIO_BUNDLE_ID ?= com.woosublee.quill.systemaudio")
        assertContains(makefile, "SYSTEM_AUDIO_DEV_APP_NAME ?= Quill SA dev")
        assertContains(makefile, "SYSTEM_AUDIO_DEV_BUNDLE_ID ?= com.woosublee.quill.systemaudio.dev")
        assertContains(makefile, "run-system-audio:")
        assertContains(makefile, "$(MAKE) run APP_NAME=\"$(SYSTEM_AUDIO_DEV_APP_NAME)\" BUNDLE_ID=\"$(SYSTEM_AUDIO_DEV_BUNDLE_ID)\"")
        assertContains(makefile, "install-system-audio:")
        assertContains(makefile, "$(MAKE) install APP_NAME=\"$(SYSTEM_AUDIO_APP_NAME)\" BUNDLE_ID=\"$(SYSTEM_AUDIO_BUNDLE_ID)\"")
    }

    private static func testReleaseWorkflowsPassBuildMetadataToMake() throws {
        let manualReleaseWorkflow = try String(contentsOfFile: ".github/workflows/manual-release.yml", encoding: .utf8)
        let releaseWorkflow = try String(contentsOfFile: ".github/workflows/release.yml", encoding: .utf8)

        assertContains(manualReleaseWorkflow, "APP_VERSION=\"${{ steps.metadata.outputs.version }}\"")
        assertContains(manualReleaseWorkflow, "BUILD_NUMBER=\"${{ github.run_number }}\"")
        assertContains(manualReleaseWorkflow, "BUILD_TAG=\"${{ steps.metadata.outputs.tag }}\"")

        assertContains(releaseWorkflow, "APP_VERSION=\"${{ steps.version.outputs.version }}\"")
        assertContains(releaseWorkflow, "BUILD_NUMBER=\"${{ github.run_number }}\"")
        assertContains(releaseWorkflow, "BUILD_TAG=\"${{ steps.version.outputs.tag }}\"")
    }

    private static func assertContains(_ text: String, _ expected: String) {
        precondition(text.contains(expected), "Expected content to contain \(expected)")
    }
}
