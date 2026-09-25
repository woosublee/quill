import Foundation

@main
struct BuildMetadataTests {
    static func main() throws {
        try testMakefileStampsLocalBuildMetadata()
        try testMakefilePrintsVersionMetadata()
        try testBuildSettingsTrackCodesignIdentity()
        try testGroupedTestArchitectureRespectsBuildOverride()
        try testAppStateRunnerRequiresIsolatedHome()
        try testMakefileSeparatesDevRunFromInstallBuild()
        try testMakefileCopiesSelectedIconToBundleIconName()
        try testMakefileBundlesLocalizationResources()
        try testMakefileBuildsAppBundleForLocalizationValidation()
        try testTranscriptionShardBuildsLocalizationResources()
        try testAppStateRunnerHasItsOwnShard()
        try testTestsWorkflowRunsRequiredChecksInParallel()
        try testMakefileExposesRepositoryValidationTargets()
        try testTestsWorkflowRequiresRepositoryValidation()
        try testReleaseWorkflowsPinActionsAndScopeGitCredentials()
        try testRepositoryMaintenanceFilesAreQuillSpecific()
        try testMakefileStripsExtendedAttributesDuringCodesignStaging()
        try testMakefileStripsExtendedAttributesDuringDmgStaging()
        try testMakefileCreatesDmgWithoutFinderMetadata()
        try testSparkleEntitlementsAllowFrameworkLoading()
        try testSparkleMetadataAndBuildIntegration()
        try testSparkleAppcastGeneratorValidatesSigningKey()
        try testReleaseWorkflowsPassBuildMetadataToMake()
        try testStableReleaseWorkflowsEnforceMonotonicUpdates()
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

        for target in [
            "check-test-wiring", "test", "test-core", "test-recording", "test-transcription",
            "test-app-state", "localization-bundle-test", "native-whisper-helper-test", "print-version-metadata"
        ] {
            assertContains(makefile, "\n\(target):")
        }
        assertContains(makefile, "TEST_BUILD_DIR = $(BUILD_DIR)/tests")
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

    private static func testGroupedTestArchitectureRespectsBuildOverride() throws {
        let makefile = try String(contentsOfFile: "Makefile", encoding: .utf8)

        assertContains(makefile, "TEST_ARCH = $(if $(filter universal,$(ARCH)),$(shell uname -m),$(ARCH))")
        assertContains(makefile, "-target $(TEST_ARCH)-apple-macosx13.0")
        assertDoesNotContain(makefile, "-target $(shell uname -m)-apple-macosx13.0")
    }

    private static func testAppStateRunnerRequiresIsolatedHome() throws {
        let makefile = try String(contentsOfFile: "Makefile", encoding: .utf8)

        assertContains(makefile, "test -n \"$$isolated_home\" || exit 1")
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

    private static func testMakefileBundlesLocalizationResources() throws {
        let makefile = try String(contentsOfFile: "Makefile", encoding: .utf8)

        assertContains(makefile, "LOCALIZATION_CATALOG = Resources/Localization/Localizable.xcstrings")
        assertContains(makefile, "xcrun xcstringstool compile")
        assertContains(makefile, "-l en -l ko")
        assertContains(makefile, "$(RESOURCES)/en.lproj")
        assertContains(makefile, "$(RESOURCES)/ko.lproj")
    }

    private static func testMakefileBuildsAppBundleForLocalizationValidation() throws {
        let makefile = try String(contentsOfFile: "Makefile", encoding: .utf8)

        assertContains(
            makefile,
            "localization-bundle-test: $(TEST_BUILD_DIR)/LocalizationResourceTests $(APP_EXECUTABLE_TARGET)"
        )
        assertContains(makefile, #"$(TEST_BUILD_DIR)/LocalizationResourceTests --bundle "$(APP_BUNDLE)""#)
        assertDoesNotContain(makefile, "/tmp/LocalizationResourceTests")
        assertDoesNotContain(makefile, "Quill Localization Test.app")
        assertDoesNotContain(makefile, "PlaceholderFixtures.strings")
    }

    private static func testTranscriptionShardBuildsLocalizationResources() throws {
        let makefile = try String(contentsOfFile: "Makefile", encoding: .utf8)

        assertContains(
            makefile,
            "_test-transcription: $(SPARKLE_STAMP) $(LOCALIZATION_STAMP)"
        )
    }

    // #357: the app-state full-source runner has its own shard, so CI compiles
    // the two full-source runners on separate runners in parallel.
    private static func testAppStateRunnerHasItsOwnShard() throws {
        let makefile = try String(contentsOfFile: "Makefile", encoding: .utf8)

        assertContains(
            makefile,
            "_test-app-state: $(SPARKLE_STAMP) $(LOCALIZATION_STAMP) $(FULL_SOURCE_APP_STATE_RUNNER)"
        )
        assertContains(makefile, "test-app-state: check-test-wiring\n\t@$(call RUN_TIMED_TARGET,_test-app-state,app-state)")
        assertContains(makefile, "\t@$(call RUN_TIMED_TARGET,_test-app-state,app-state)\n\n_test-core:")
        assertContains(makefile, "_test-core _test-recording _test-transcription _test-app-state test-local-ai-integration")
        let transcriptionLines = makefile
            .components(separatedBy: "\n")
            .filter { $0.hasPrefix("_test-transcription:") }
        precondition(transcriptionLines.count == 1, "expected one _test-transcription rule")
        // The transcription shard must not also build the app-state runner.
        assertDoesNotContain(transcriptionLines[0], "$(FULL_SOURCE_APP_STATE_RUNNER)")
    }

    private static func testTestsWorkflowRunsRequiredChecksInParallel() throws {
        let workflow = try String(contentsOfFile: ".github/workflows/tests.yml", encoding: .utf8)

        for target in ["test-core", "test-recording", "test-transcription", "test-app-state"] {
            assertContains(workflow, "target: \(target)")
        }
        assertContains(workflow, "fail-fast: false")
        assertContains(workflow, "make localization-bundle-test CODESIGN_IDENTITY=-")
        assertContains(workflow, "timeout-minutes: 25")
        assertContains(workflow, "tests:\n    name: Tests")
        assertContains(workflow, "if: ${{ always() }}")
        assertContains(workflow, "TEST_SHARDS_RESULT: ${{ needs.test-shards.result }}")
        assertContains(workflow, "LOCALIZATION_RESULT: ${{ needs.localization.result }}")
        assertContains(workflow, "VALIDATION_RESULT: ${{ needs.repository-validation.result }}")
    }

    private static func testMakefileExposesRepositoryValidationTargets() throws {
        let makefile = try String(contentsOfFile: "Makefile", encoding: .utf8)

        assertContains(makefile, "\nvalidate:")
        assertContains(makefile, "\ncheck: validate test")
    }

    private static func testTestsWorkflowRequiresRepositoryValidation() throws {
        let workflow = try String(contentsOfFile: ".github/workflows/tests.yml", encoding: .utf8)

        assertContains(workflow, "repository-validation:")
        assertContains(workflow, "run: make validate")
        assertContains(workflow, "git diff --check")
        assertContains(workflow, "      - repository-validation")
        assertContains(workflow, "VALIDATION_RESULT: ${{ needs.repository-validation.result }}")
        assertContains(workflow, "test \"$VALIDATION_RESULT\" = \"success\"")
        assertDoesNotContain(workflow, "make check")
    }

    private static func testReleaseWorkflowsPinActionsAndScopeGitCredentials() throws {
        let releaseWorkflowPaths = [
            ".github/workflows/dev-release.yml",
            ".github/workflows/manual-release.yml",
            ".github/workflows/release.yml",
            ".github/workflows/self-signed-release.yml",
        ]
        let workflowPaths = releaseWorkflowPaths + [".github/workflows/tests.yml"]

        for path in workflowPaths {
            let workflow = try String(contentsOfFile: path, encoding: .utf8)
            let checkoutCount = workflow.components(separatedBy: "actions/checkout@").count - 1
            let credentialOptOutCount = workflow.components(
                separatedBy: "persist-credentials: false"
            ).count - 1

            precondition(checkoutCount > 0, "Expected checkout action in \(path)")
            precondition(
                checkoutCount == credentialOptOutCount,
                "Every checkout in \(path) must disable persisted credentials"
            )

            for line in workflow.split(separator: "\n") {
                guard let usesRange = line.range(of: "uses: ") else { continue }
                let action = line[usesRange.upperBound...].split(separator: " ", maxSplits: 1)[0]
                guard let atIndex = action.lastIndex(of: "@") else {
                    preconditionFailure("Expected pinned action reference in \(path): \(action)")
                }
                let revision = String(action[action.index(after: atIndex)...])
                assertMatches(revision, "^[0-9a-f]{40}$")
            }
        }

        for path in releaseWorkflowPaths {
            let workflow = try String(contentsOfFile: path, encoding: .utf8)
            assertContains(workflow, "softprops/action-gh-release@")
            assertDoesNotContain(workflow, "Install build tools")
            assertDoesNotContain(workflow, "brew install create-dmg fileicon")
            assertDoesNotContain(workflow, "aws/tap")
        }

        for path in [
            ".github/workflows/dev-release.yml",
            ".github/workflows/release.yml",
            ".github/workflows/self-signed-release.yml",
        ] {
            let workflow = try String(contentsOfFile: path, encoding: .utf8)
            assertContains(workflow, "GITHUB_TOKEN: ${{ github.token }}")
            assertContains(workflow, "AUTHORIZATION: basic $AUTHORIZATION")
            assertContains(workflow, "http.https://github.com/.extraheader")
            assertContains(workflow, "--unset-all http.https://github.com/.extraheader")
        }
    }

    private static func testRepositoryMaintenanceFilesAreQuillSpecific() throws {
        let agents = try String(contentsOfFile: "AGENTS.md", encoding: .utf8)
        let bug = try String(contentsOfFile: ".github/ISSUE_TEMPLATE/bug.yml", encoding: .utf8)
        let feature = try String(contentsOfFile: ".github/ISSUE_TEMPLATE/feature.yml", encoding: .utf8)
        let config = try String(contentsOfFile: ".github/ISSUE_TEMPLATE/config.yml", encoding: .utf8)
        let dependabot = try String(contentsOfFile: ".github/dependabot.yml", encoding: .utf8)
        let pullRequest = try String(contentsOfFile: ".github/pull_request_template.md", encoding: .utf8)

        for content in [agents, bug, feature, pullRequest] {
            assertContains(content, "Quill")
            assertDoesNotContain(content, "FreeFlow")
            assertDoesNotContain(content, "zachlatta/freeflow")
        }
        assertContains(agents, "self-signed-release.yml")
        assertContains(agents, "Google Calendar OAuth")
        assertContains(agents, "appcast.xml")
        assertContains(config, "blank_issues_enabled: true")
        assertDoesNotContain(config, "discussions")
        assertContains(dependabot, "timezone: Asia/Seoul")
        assertContains(pullRequest, "`make check`")
        precondition(!FileManager.default.fileExists(atPath: ".github/workflows/check.yml"))
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

    private static func testSparkleEntitlementsAllowFrameworkLoading() throws {
        let entitlements = try String(contentsOfFile: "Quill.entitlements", encoding: .utf8)

        assertContains(entitlements, "<key>com.apple.security.device.audio-input</key>")
        assertContains(entitlements, "<key>com.apple.security.cs.disable-library-validation</key>")
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
        assertContains(infoPlist, "<key>SUScheduledCheckInterval</key>")
        assertContains(infoPlist, "<integer>86400</integer>")
        assertDoesNotContain(infoPlist, "<key>SUUpdateCheckInterval</key>")

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

    private static func testSparkleAppcastGeneratorValidatesSigningKey() throws {
        let generator = try String(contentsOfFile: "scripts/generate-sparkle-appcast.sh", encoding: .utf8)

        assertContains(generator, "validate-sparkle-key.swift")
        assertContains(generator, "SUPublicEDKey")
        assertContains(generator, "--verify --ed-key-file -")
        assertContains(generator, #"printf '%s\n' "$private_key" |"#)
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

    private static func testStableReleaseWorkflowsEnforceMonotonicUpdates() throws {
        let stableWorkflows = [
            try String(contentsOfFile: ".github/workflows/self-signed-release.yml", encoding: .utf8),
            try String(contentsOfFile: ".github/workflows/release.yml", encoding: .utf8),
        ]
        let manualWorkflow = try String(contentsOfFile: ".github/workflows/manual-release.yml", encoding: .utf8)
        let devWorkflow = try String(contentsOfFile: ".github/workflows/dev-release.yml", encoding: .utf8)

        for workflow in stableWorkflows {
            assertContains(workflow, "group: quill-official-stable-release")
            assertContains(workflow, "cancel-in-progress: false")
            assertContains(workflow, "Validate stable release ordering")
            assertContains(workflow, "scripts/validate_stable_release.py preflight")
            assertContains(workflow, "Verify published latest release")
            assertContains(workflow, "scripts/validate_stable_release.py verify-latest")
            assertContains(workflow, "--attempts 12")
            assertContains(workflow, "--retry-delay 10")
            assertContains(workflow, #"^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$"#)
            assertContains(workflow, "GITHUB_TOKEN: ${{ github.token }}")
            assertAppearsInOrder(
                workflow,
                [
                    "Validate stable release ordering",
                    "Stamp app version",
                    "Create tag",
                    "Create Release",
                    "Verify published latest release",
                ]
            )
        }

        assertDoesNotContain(manualWorkflow, "validate_stable_release.py")
        assertDoesNotContain(devWorkflow, "validate_stable_release.py")
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

    private static func assertAppearsInOrder(_ text: String, _ markers: [String]) {
        var searchStart = text.startIndex
        for marker in markers {
            guard let range = text[searchStart...].range(of: marker) else {
                preconditionFailure("Expected content to contain \(marker) after previous markers")
            }
            searchStart = range.upperBound
        }
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
