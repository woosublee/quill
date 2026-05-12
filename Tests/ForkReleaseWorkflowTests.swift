import Foundation

@main
struct ForkReleaseWorkflowTests {
    static func main() throws {
        let workflowPath = ".github/workflows/fork-release.yml"
        guard FileManager.default.fileExists(atPath: workflowPath) else {
            fatalError("Fork release workflow is missing at \(workflowPath)")
        }

        let workflow = try String(contentsOfFile: workflowPath, encoding: .utf8)

        assertContains(workflow, "name: Fork Release")
        assertContains(workflow, "workflow_dispatch:")
        assertContains(workflow, "tag:")
        assertContains(workflow, "release_name:")
        assertContains(workflow, "release_notes:")
        assertContains(workflow, "CODESIGN_IDENTITY=-")
        assertContains(workflow, "Quill.dmg")
        assertContains(workflow, "IS_PRERELEASE=false")
        assertContains(workflow, "MAKE_LATEST=true")
        assertContains(workflow, "IS_PRERELEASE=true")
        assertContains(workflow, "MAKE_LATEST=false")
        assertContains(workflow, "VERSION=\"${TAG#v}\"")
        assertContains(workflow, "RELEASE_NAME_DELIM=\"RELEASE_NAME_$(uuidgen)\"")
        assertContains(workflow, "echo \"release_name<<$RELEASE_NAME_DELIM\"")
        assertContains(workflow, "echo \"$RELEASE_NAME_DELIM\"")
        assertDoesNotContain(workflow, "release_name=$RELEASE_NAME")
        assertContains(workflow, "plutil -replace CFBundleShortVersionString -string \"${{ steps.metadata.outputs.version }}\" Info.plist")
        assertContains(workflow, "plutil -replace QuillBuildTag -string \"${{ steps.metadata.outputs.tag }}\" Info.plist")
        assertContains(workflow, "prerelease: ${{ steps.metadata.outputs.prerelease }}")
        assertContains(workflow, "make_latest: ${{ steps.metadata.outputs.make_latest }}")
        assertContains(workflow, "macOS may show a first-launch security warning")
        assertContains(workflow, "DELIM=\"RELEASE_BODY_$(uuidgen)\"")
        assertContains(workflow, "echo \"body<<$DELIM\"")
        assertContains(workflow, "echo \"$DELIM\"")
        assertDoesNotContain(workflow, "body<<EOF")
        assertContains(workflow, "Refuse existing tag")
        assertContains(workflow, "refs/tags/$TAG")
        assertContains(workflow, "already exists")
        assertDoesNotContain(workflow, "Quill-Unsigned.dmg")
        assertDoesNotContain(workflow, "Unsigned Prerelease")
        assertDoesNotContain(workflow, "unsigned build warning")
        assertDoesNotContain(workflow, "notarytool")
        assertDoesNotContain(workflow, "DEVELOPER_ID_CERTIFICATE")
        assertDoesNotContain(workflow, "APPLE_APP_PASSWORD")
        assertDoesNotContain(workflow, "APPLE_TEAM_ID")

        print("ForkReleaseWorkflowTests passed")
    }

    private static func assertContains(_ text: String, _ expected: String) {
        precondition(text.contains(expected), "Expected workflow to contain \(expected)")
    }

    private static func assertDoesNotContain(_ text: String, _ unexpected: String) {
        precondition(!text.contains(unexpected), "Expected workflow not to contain \(unexpected)")
    }
}
