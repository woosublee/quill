import Foundation

@main
struct BuildMetadataTests {
    static func main() throws {
        try testMakefileStampsLocalBuildMetadata()
        try testBuildSettingsTrackCodesignIdentity()
        try testMakefileSeparatesDevRunFromInstallBuild()
        try testMakefileCopiesSelectedIconToBundleIconName()
        try testMakefileStripsExtendedAttributesDuringCodesignStaging()
        try testMakefileStripsExtendedAttributesDuringDmgStaging()
        try testMakefileCreatesDmgWithoutFinderMetadata()
        try testReleaseWorkflowsPassBuildMetadataToMake()
        try testNotarizedReleaseWorkflowIsManualByDefault()
        try testSettingsSeparatesVersionBuildAndReleaseTag()
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

        assertContains(makefile, "CODESIGN_IDENTITY ?= Quill")
        assertContains(makefile, "$(CODESIGN_IDENTITY)")
        assertContains(makefile, "$(BUILD_TAG)\" \"$(GOOGLE_CALENDAR_OAUTH_CLIENT_ID)\" \"$(GOOGLE_CALENDAR_OAUTH_CLIENT_SECRET)\" \"$(CODESIGN_IDENTITY)")
    }

    private static func testMakefileSeparatesDevRunFromInstallBuild() throws {
        let makefile = try String(contentsOfFile: "Makefile", encoding: .utf8)

        assertContains(makefile, "APP_NAME ?= Quill")
        assertContains(makefile, "BUNDLE_ID ?= com.woosublee.quill")
        assertContains(makefile, "DEV_APP_NAME ?= Quill Dev")
        assertContains(makefile, "DEV_BUNDLE_ID ?= com.woosublee.quill.dev")
        assertContains(makefile, "run:\n\t$(MAKE) all APP_NAME=\"$(DEV_APP_NAME)\" BUNDLE_ID=\"$(DEV_BUNDLE_ID)\"")
        assertContains(makefile, "\topen \"$(BUILD_DIR)/$(DEV_APP_NAME).app\"")
        assertContains(makefile, "install: all\n\t@mkdir -p \"/Applications/$(APP_NAME).app\"")
    }

    private static func testMakefileCopiesSelectedIconToBundleIconName() throws {
        let makefile = try String(contentsOfFile: "Makefile", encoding: .utf8)
        let infoPlist = try String(contentsOfFile: "Info.plist", encoding: .utf8)

        assertContains(infoPlist, "<key>CFBundleIconFile</key>\n    <string>AppIcon</string>")
        assertContains(makefile, "ICON_ICNS = Resources/AppIcon-Dev.icns")
        assertContains(makefile, "@cp $(ICON_ICNS) \"$(RESOURCES)/AppIcon.icns\"")
    }

    private static func testMakefileStripsExtendedAttributesDuringCodesignStaging() throws {
        let makefile = try String(contentsOfFile: "Makefile", encoding: .utf8)

        assertContains(makefile, "@ditto --norsrc --noextattr \"$(APP_BUNDLE)\" \"$(BUILD_DIR)/codesign-staging/$(APP_NAME).app\"")
        assertContains(makefile, "@ditto --norsrc --noextattr \"$(BUILD_DIR)/codesign-staging/$(APP_NAME).app\" \"$(APP_BUNDLE)\"\n\t@xattr -cr \"$(APP_BUNDLE)\"")
    }

    private static func testMakefileStripsExtendedAttributesDuringDmgStaging() throws {
        let makefile = try String(contentsOfFile: "Makefile", encoding: .utf8)

        assertContains(makefile, "xattr -cr \"$(APP_BUNDLE)\"")
        assertContains(makefile, "ditto --norsrc --noextattr \"$(APP_BUNDLE)\" \"$$mount_dir/$(APP_NAME).app\"")
        assertContains(makefile, "xattr -cr \"$$mount_dir/$(APP_NAME).app\"")
        assertDoesNotContain(makefile, "@cp -R \"$(APP_BUNDLE)\" $(BUILD_DIR)/dmg-staging/")
    }

    private static func testMakefileCreatesDmgWithoutFinderMetadata() throws {
        let makefile = try String(contentsOfFile: "Makefile", encoding: .utf8)

        assertContains(makefile, "hdiutil create -size 120m -fs HFS+ -volname \"$(APP_NAME)\"")
        assertContains(makefile, "ditto --norsrc --noextattr \"$(APP_BUNDLE)\" \"$$mount_dir/$(APP_NAME).app\"")
        assertContains(makefile, "ln -s /Applications \"$$mount_dir/Applications\"")
        assertContains(makefile, "xattr -cr \"$$mount_dir/$(APP_NAME).app\"")
        assertContains(makefile, "hdiutil convert \"$$rw_dmg\" -format UDZO -o \"$(BUILD_DIR)/$(APP_NAME).dmg\"")
        assertContains(makefile, "@xattr -cr \"$(APP_BUNDLE)\"\n\t@echo \"Created $(BUILD_DIR)/$(APP_NAME).dmg\"")
        assertDoesNotContain(makefile, "create-dmg")
        assertDoesNotContain(makefile, "fileicon set")
    }

    private static func testReleaseWorkflowsPassBuildMetadataToMake() throws {
        let manualReleaseWorkflow = try String(contentsOfFile: ".github/workflows/manual-release.yml", encoding: .utf8)
        let releaseWorkflow = try String(contentsOfFile: ".github/workflows/release.yml", encoding: .utf8)

        assertContains(manualReleaseWorkflow, "APP_VERSION=\"${{ steps.metadata.outputs.version }}\"")
        assertContains(manualReleaseWorkflow, "BUILD_NUMBER=\"${{ steps.metadata.outputs.build_number }}\"")
        assertContains(manualReleaseWorkflow, "BUILD_TAG=\"${{ steps.metadata.outputs.tag }}\"")

        assertContains(releaseWorkflow, "APP_VERSION=\"${{ steps.version.outputs.version }}\"")
        assertContains(releaseWorkflow, "BUILD_NUMBER=\"${{ steps.version.outputs.build_number }}\"")
        assertContains(releaseWorkflow, "BUILD_TAG=\"${{ steps.version.outputs.tag }}\"")
    }

    private static func testNotarizedReleaseWorkflowIsManualByDefault() throws {
        let releaseWorkflow = try String(contentsOfFile: ".github/workflows/release.yml", encoding: .utf8)

        assertContains(releaseWorkflow, "name: Official Notarized Release")
        assertContains(releaseWorkflow, "workflow_dispatch:")
        assertContains(releaseWorkflow, "# To re-enable automatic notarized releases from version tags:")
        assertContains(releaseWorkflow, "# push:")
        assertContains(releaseWorkflow, "#   tags:")
        assertContains(releaseWorkflow, "#     - \"v*.*.*\"")
        assertContains(releaseWorkflow, "TAG=\"${{ inputs.tag }}\"")
        assertContains(releaseWorkflow, "BUILD_NUMBER=\"${{ inputs.build_number }}\"")
        assertDoesNotContain(releaseWorkflow, "on:\n  push:")
        assertDoesNotContain(releaseWorkflow, "BUILD_NUMBER=\"${{ github.run_number }}\"")
    }

    private static func testSettingsSeparatesVersionBuildAndReleaseTag() throws {
        let settingsView = try String(contentsOfFile: "Sources/SettingsView.swift", encoding: .utf8)

        assertContains(settingsView, "private var appReleaseTag: String")
        assertContains(settingsView, "Bundle.main.object(forInfoDictionaryKey: \"CFBundleVersion\") as? String ?? \"unknown\"")
        assertContains(settingsView, "Bundle.main.object(forInfoDictionaryKey: \"QuillBuildTag\") as? String ?? \"unknown\"")
        assertContains(settingsView, "Text(\"Version\")")
        assertContains(settingsView, "Text(\"Build number\")")
        assertContains(settingsView, "Text(\"Release tag\")")
        assertContains(settingsView, #"\(appDisplayName) \(appVersion) (build \(appBuildNumber), \(appReleaseTag))"#)
    }

    private static func assertContains(_ text: String, _ expected: String) {
        precondition(text.contains(expected), "Expected content to contain \(expected)")
    }

    private static func assertDoesNotContain(_ text: String, _ unexpected: String) {
        precondition(!text.contains(unexpected), "Expected content not to contain \(unexpected)")
    }
}
