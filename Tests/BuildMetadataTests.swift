import Foundation

@main
struct BuildMetadataTests {
    static func main() throws {
        try testMakefileStampsLocalBuildMetadata()
        try testMakefilePrintsVersionMetadata()
        try testBuildSettingsTrackCodesignIdentity()
        try testMakefileSeparatesDevRunFromInstallBuild()
        try testMakefileCopiesSelectedIconToBundleIconName()
        try testMakefileStripsExtendedAttributesDuringCodesignStaging()
        try testMakefileStripsExtendedAttributesDuringDmgStaging()
        try testMakefileCreatesDmgWithoutFinderMetadata()
        try testSparkleMetadataAndBuildIntegration()
        try testReleaseWorkflowsPassBuildMetadataToMake()
        try testNotarizedReleaseWorkflowIsManualByDefault()
        try testSettingsSeparatesVersionBuildAndReleaseTag()
        print("BuildMetadataTests passed")
    }

    private static func testMakefileStampsLocalBuildMetadata() throws {
        let makefile = try String(contentsOfFile: "Makefile", encoding: .utf8)
        let versionFile = try String(contentsOfFile: "version.mk", encoding: .utf8)

        let versionMetadata = parseVersionMetadata(versionFile)
        assertMatches(versionMetadata["APP_VERSION"], #"^\d+\.\d+\.\d+$"#)
        assertMatches(versionMetadata["BUILD_NUMBER"], #"^[1-9]\d*$"#)
        assertMatches(versionMetadata["BUILD_TAG"], #"^v\d+\.\d+\.\d+$"#)
        assertContains(makefile, "-include version.mk")
        assertContains(makefile, "APP_VERSION ?= $(patsubst v%,%,$(if $(GIT_RELEASE_TAG),$(GIT_RELEASE_TAG),v0.0.1))")
        assertContains(makefile, "BUILD_NUMBER ?= 1")
        assertDoesNotContain(makefile, "GIT_COMMIT_COUNT := $(shell git rev-list --count HEAD")
        assertDoesNotContain(makefile, "BUILD_NUMBER ?= $(if $(GIT_COMMIT_COUNT),$(GIT_COMMIT_COUNT),1)")
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

    private static func testMakefilePrintsVersionMetadata() throws {
        let makefile = try String(contentsOfFile: "Makefile", encoding: .utf8)

        assertContains(makefile, ".PHONY: all clean run icon dmg codesign-dmg notarize install reset-permissions install-and-run test print-app-version print-build-number print-build-tag print-version-metadata FORCE")
        assertContains(makefile, "print-app-version:")
        assertContains(makefile, "print-build-number:")
        assertContains(makefile, "print-build-tag:")
        assertContains(makefile, "print-version-metadata:")
        assertContains(makefile, "@printf '%s\\n' \"$(APP_VERSION)\"")
        assertContains(makefile, "@printf '%s\\n' \"$(BUILD_NUMBER)\"")
        assertContains(makefile, "@printf '%s\\n' \"$(BUILD_TAG)\"")
        assertContains(makefile, "app_version=%s\\nbuild_number=%s\\nbuild_tag=%s\\n")
        assertContains(makefile, "\"$(APP_VERSION)\" \"$(BUILD_NUMBER)\" \"$(BUILD_TAG)\"")
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

        assertContains(makefile, "dmg_size_mb=$$(($$(du -sm \"$(APP_BUNDLE)\" | cut -f1) + 64))")
        assertContains(makefile, "hdiutil create -size \"$${dmg_size_mb}m\" -fs HFS+ -volname \"$(APP_NAME)\"")
        assertContains(makefile, "trap 'hdiutil detach \"$$mount_dir\" >/dev/null 2>&1 || true; rm -f \"$$rw_dmg\"; rm -rf \"$$mount_dir\"' EXIT")
        assertContains(makefile, "ditto --norsrc --noextattr \"$(APP_BUNDLE)\" \"$$mount_dir/$(APP_NAME).app\"")
        assertContains(makefile, "ln -s /Applications \"$$mount_dir/Applications\"")
        assertContains(makefile, "xattr -cr \"$$mount_dir/$(APP_NAME).app\"")
        assertContains(makefile, "codesign --verify --deep --strict --verbose=2 \"$$mount_dir/$(APP_NAME).app\"")
        assertContains(makefile, "hdiutil convert \"$$rw_dmg\" -format UDZO -o \"$(BUILD_DIR)/$(APP_NAME).dmg\"")
        assertDoesNotContain(makefile, "create-dmg")
        assertDoesNotContain(makefile, "fileicon set")
        assertDoesNotContain(makefile, "hdiutil create -srcfolder")
        assertDoesNotContain(makefile, "-size 120m")
    }

    private static func testSparkleMetadataAndBuildIntegration() throws {
        let makefile = try String(contentsOfFile: "Makefile", encoding: .utf8)
        let infoPlist = try String(contentsOfFile: "Info.plist", encoding: .utf8)
        let package = try String(contentsOfFile: "Package.swift", encoding: .utf8)

        assertContains(package, #".package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.2")"#)
        assertContains(package, #".product(name: "Sparkle", package: "Sparkle")"#)
        assertContains(infoPlist, "<key>SUFeedURL</key>")
        assertContains(infoPlist, "https://github.com/woosublee/quill/releases/latest/download/appcast.xml")
        assertContains(infoPlist, "<key>SUPublicEDKey</key>")
        assertContains(infoPlist, "CnlcVsnQ8m/2VyZD7xL4ovP/ukAJtDJY19aVlfOSoOg=")
        assertContains(infoPlist, "<key>SUEnableAutomaticChecks</key>")
        assertContains(infoPlist, "<key>SUAutomaticallyUpdate</key>")
        assertContains(infoPlist, "<key>SUUpdateCheckInterval</key>")
        assertContains(infoPlist, "<integer>604800</integer>")

        assertContains(makefile, "SPARKLE_VERSION ?= 2.9.2")
        assertContains(makefile, "swift build --product SparkleResolver")
        assertContains(makefile, "Sparkle.framework")
        assertContains(makefile, "-framework Sparkle")
        assertContains(makefile, "@executable_path/../Frameworks")
        assertContains(makefile, "Contents/Frameworks")
        assertContains(makefile, "Versions/Current/XPCServices")
        assertContains(makefile, "Versions/Current/Updater.app")
        assertContains(makefile, "Versions/Current/Autoupdate")
    }

    private static func testReleaseWorkflowsPassBuildMetadataToMake() throws {
        let manualReleaseWorkflow = try String(contentsOfFile: ".github/workflows/manual-release.yml", encoding: .utf8)
        let releaseWorkflow = try String(contentsOfFile: ".github/workflows/release.yml", encoding: .utf8)
        let devReleaseWorkflow = try String(contentsOfFile: ".github/workflows/dev-release.yml", encoding: .utf8)

        assertContains(manualReleaseWorkflow, "APP_VERSION=\"$(make -s print-app-version)\"")
        assertContains(manualReleaseWorkflow, "BUILD_NUMBER=\"$(make -s print-build-number)\"")
        assertContains(manualReleaseWorkflow, "BUILD_TAG=\"$(make -s print-build-tag)\"")
        assertContains(releaseWorkflow, "APP_VERSION=\"$(make -s print-app-version)\"")
        assertContains(releaseWorkflow, "BUILD_NUMBER=\"$(make -s print-build-number)\"")
        assertContains(releaseWorkflow, "BUILD_TAG=\"$(make -s print-build-tag)\"")

        assertContains(manualReleaseWorkflow, "APP_VERSION=\"${{ steps.metadata.outputs.version }}\"")
        assertContains(manualReleaseWorkflow, "BUILD_NUMBER=\"${{ steps.metadata.outputs.build_number }}\"")
        assertContains(manualReleaseWorkflow, "BUILD_TAG=\"${{ steps.metadata.outputs.tag }}\"")

        assertContains(releaseWorkflow, "APP_VERSION=\"${{ steps.version.outputs.version }}\"")
        assertContains(releaseWorkflow, "BUILD_NUMBER=\"${{ steps.version.outputs.build_number }}\"")
        assertContains(releaseWorkflow, "BUILD_TAG=\"${{ steps.version.outputs.tag }}\"")

        assertContains(devReleaseWorkflow, "BASE_VERSION=\"$(make -s print-app-version)\"")
        assertContains(devReleaseWorkflow, "BUILD_NUMBER=\"$(make -s print-build-number)\"")
        assertContains(devReleaseWorkflow, #"BUILD_TAG="dev-${SHORT_SHA}""#)
        assertContains(devReleaseWorkflow, #"BUILD_NUMBER="${{ steps.version.outputs.build_number }}""#)
        assertContains(devReleaseWorkflow, #"BUILD_TAG="${{ steps.version.outputs.build_tag }}""#)
        assertContains(devReleaseWorkflow, #"run: make ARCH=universal CODESIGN_IDENTITY="$CODESIGN_IDENTITY" APP_VERSION="${{ steps.version.outputs.version }}" BUILD_NUMBER="${{ steps.version.outputs.build_number }}" BUILD_TAG="${{ steps.version.outputs.build_tag }}""#)
        assertContains(devReleaseWorkflow, #"run: make dmg ARCH=universal CODESIGN_IDENTITY="$CODESIGN_IDENTITY" APP_VERSION="${{ steps.version.outputs.version }}" BUILD_NUMBER="${{ steps.version.outputs.build_number }}" BUILD_TAG="${{ steps.version.outputs.build_tag }}""#)
        assertContains(devReleaseWorkflow, #"plutil -replace CFBundleVersion -string "${{ steps.version.outputs.build_number }}" Info.plist"#)
        assertDoesNotContain(devReleaseWorkflow, #"plutil -replace CFBundleVersion -string "${{ github.run_number }}" Info.plist"#)
        assertContains(devReleaseWorkflow, #"plutil -replace QuillBuildTag -string "${{ steps.version.outputs.build_tag }}" Info.plist"#)
        assertContains(releaseWorkflow, "Generate Sparkle appcast")
        assertContains(releaseWorkflow, "SPARKLE_PRIVATE_KEY: ${{ secrets.SPARKLE_PRIVATE_KEY }}")
        assertContains(releaseWorkflow, "scripts/generate-sparkle-appcast.sh")
        assertContains(releaseWorkflow, "appcast.xml")
        assertContains(releaseWorkflow, "Quill.dmg")
        assertDoesNotContain(devReleaseWorkflow, "plutil -replace FreeFlowBuildTag")
    }

    private static func testNotarizedReleaseWorkflowIsManualByDefault() throws {
        let releaseWorkflow = try String(contentsOfFile: ".github/workflows/release.yml", encoding: .utf8)

        assertContains(releaseWorkflow, "name: Official Notarized Release")
        assertContains(releaseWorkflow, "workflow_dispatch:")
        assertContains(releaseWorkflow, "# To re-enable automatic notarized releases from version tags:")
        assertContains(releaseWorkflow, "# push:")
        assertContains(releaseWorkflow, "#   tags:")
        assertContains(releaseWorkflow, "#     - \"v*.*.*\"")
        assertContains(releaseWorkflow, "INPUT_TAG: ${{ inputs.tag }}")
        assertContains(releaseWorkflow, "TAG=\"$INPUT_TAG\"")
        assertContains(releaseWorkflow, "BUILD_NUMBER=\"$(make -s print-build-number)\"")
        assertDoesNotContain(releaseWorkflow, "build_number:")
        assertDoesNotContain(releaseWorkflow, "BUILD_NUMBER=\"${{ inputs.build_number }}\"")
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

    private static func parseVersionMetadata(_ text: String) -> [String: String] {
        var metadata: [String: String] = [:]

        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ":=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 {
                metadata[parts[0]] = parts[1]
            }
        }

        return metadata
    }

    private static func assertContains(_ text: String, _ expected: String) {
        precondition(text.contains(expected), "Expected content to contain \(expected)")
    }

    private static func assertDoesNotContain(_ text: String, _ unexpected: String) {
        precondition(!text.contains(unexpected), "Expected content not to contain \(unexpected)")
    }

    private static func assertMatches(_ value: String?, _ pattern: String) {
        guard let value else {
            preconditionFailure("Expected metadata value matching \(pattern)")
        }

        precondition(value.range(of: pattern, options: .regularExpression) != nil, "Expected \(value) to match \(pattern)")
    }
}
