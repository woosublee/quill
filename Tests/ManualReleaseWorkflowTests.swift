import Foundation

@main
struct ManualReleaseWorkflowTests {
    static func main() throws {
        let workflowPath = ".github/workflows/manual-release.yml"
        guard FileManager.default.fileExists(atPath: workflowPath) else {
            fatalError("Manual release workflow is missing at \(workflowPath)")
        }

        let workflow = try String(contentsOfFile: workflowPath, encoding: .utf8)

        assertContains(workflow, "name: Manual Release")
        assertContains(workflow, "workflow_dispatch:")
        assertContains(workflow, "tag:")
        assertDoesNotContain(workflow, "build_number:")
        assertContains(workflow, "APP_VERSION=\"$(make -s print-app-version)\"")
        assertContains(workflow, "BUILD_NUMBER=\"$(make -s print-build-number)\"")
        assertContains(workflow, "BUILD_TAG=\"$(make -s print-build-tag)\"")
        assertContains(workflow, "if [ \"$TAG\" != \"$BUILD_TAG\" ]; then")
        assertContains(workflow, "Workflow tag $TAG must match BUILD_TAG $BUILD_TAG from version.mk.")
        assertContains(workflow, "if [ \"$VERSION\" != \"$APP_VERSION\" ]; then")
        assertContains(workflow, "Workflow version $VERSION must match APP_VERSION $APP_VERSION from version.mk.")
        assertContains(workflow, "release_name:")
        assertContains(workflow, "release_notes:")
        assertContains(workflow, "CODESIGN_IDENTITY=-")
        assertContains(workflow, "Quill-Manual.dmg")
        assertDoesNotContain(workflow, "mv build/Quill.dmg Quill.dmg")
        assertContains(workflow, "IS_PRERELEASE=true")
        assertContains(workflow, "MAKE_LATEST=false")
        assertDoesNotContain(workflow, "IS_PRERELEASE=false")
        assertDoesNotContain(workflow, "MAKE_LATEST=true")
        assertContains(workflow, "VERSION=\"${TAG#v}\"")
        assertContains(workflow, "if ! [[ \"$BUILD_NUMBER\" =~ ^[1-9][0-9]*$ ]]")
        assertContains(workflow, "echo \"build_number=$BUILD_NUMBER\" >> \"$GITHUB_OUTPUT\"")
        assertContains(workflow, "RELEASE_NAME_DELIM=\"RELEASE_NAME_$(uuidgen)\"")
        assertContains(workflow, "echo \"release_name<<$RELEASE_NAME_DELIM\"")
        assertContains(workflow, "echo \"$RELEASE_NAME_DELIM\"")
        assertDoesNotContain(workflow, "release_name=$RELEASE_NAME")
        assertContains(workflow, "plutil -replace CFBundleShortVersionString -string \"${{ steps.metadata.outputs.version }}\" Info.plist")
        assertContains(workflow, "plutil -replace CFBundleVersion -string \"${{ steps.metadata.outputs.build_number }}\" Info.plist")
        assertContains(workflow, "plutil -replace QuillBuildTag -string \"${{ steps.metadata.outputs.tag }}\" Info.plist")
        assertContains(workflow, "APP_VERSION=\"${{ steps.metadata.outputs.version }}\"")
        assertContains(workflow, "BUILD_NUMBER=\"${{ steps.metadata.outputs.build_number }}\"")
        assertContains(workflow, "BUILD_TAG=\"${{ steps.metadata.outputs.tag }}\"")
        assertContains(workflow, "prerelease: ${{ steps.metadata.outputs.prerelease }}")
        assertContains(workflow, "make_latest: ${{ steps.metadata.outputs.make_latest }}")
        assertContains(workflow, "macOS may show a first-launch security warning")
        assertContains(workflow, "not used by Sparkle automatic updates")
        assertContains(workflow, ".github/scripts/changelog-section.sh \"${{ steps.metadata.outputs.version }}\" > \"$RUNNER_TEMP/release-notes.md\"")
        assertContains(workflow, "cat \"$RUNNER_TEMP/release-notes.md\"")
        assertContains(workflow, "DELIM=\"RELEASE_BODY_$(uuidgen)\"")
        assertContains(workflow, "echo \"body<<$DELIM\"")
        assertContains(workflow, "echo \"$DELIM\"")
        assertDoesNotContain(workflow, "body<<EOF")
        assertContains(workflow, "Refuse existing tag")
        assertContains(workflow, "refs/tags/$TAG")
        assertContains(workflow, "already exists")
        assertDoesNotContain(workflow, "files: |\n            Quill.dmg")
        assertDoesNotContain(workflow, "Quill-Unsigned.dmg")
        assertDoesNotContain(workflow, "Unsigned Prerelease")
        assertDoesNotContain(workflow, "unsigned build warning")
        assertDoesNotContain(workflow, "notarytool")
        assertDoesNotContain(workflow, "DEVELOPER_ID_CERTIFICATE")
        assertDoesNotContain(workflow, "APPLE_APP_PASSWORD")
        assertDoesNotContain(workflow, "APPLE_TEAM_ID")

        print("ManualReleaseWorkflowTests passed")
    }

    private static func assertContains(_ text: String, _ expected: String) {
        precondition(text.contains(expected), "Expected workflow to contain \(expected)")
    }

    private static func assertDoesNotContain(_ text: String, _ unexpected: String) {
        precondition(!text.contains(unexpected), "Expected workflow not to contain \(unexpected)")
    }
}
