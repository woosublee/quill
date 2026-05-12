import Foundation

@main
struct ForkPrereleaseWorkflowTests {
    static func main() throws {
        let workflowPath = ".github/workflows/fork-prerelease.yml"
        guard FileManager.default.fileExists(atPath: workflowPath) else {
            fatalError("Fork prerelease workflow is missing at \(workflowPath)")
        }

        let workflow = try String(contentsOfFile: workflowPath, encoding: .utf8)

        assertContains(workflow, "name: Fork Prerelease")
        assertContains(workflow, "workflow_dispatch:")
        assertContains(workflow, "tag:")
        assertContains(workflow, "release_name:")
        assertContains(workflow, "release_notes:")
        assertContains(workflow, "CODESIGN_IDENTITY=-")
        assertContains(workflow, "Quill-Unsigned.dmg")
        assertContains(workflow, "prerelease: true")
        assertContains(workflow, "make_latest: false")
        assertContains(workflow, "not Apple-notarized")
        assertDoesNotContain(workflow, "notarytool")
        assertDoesNotContain(workflow, "DEVELOPER_ID_CERTIFICATE")
        assertDoesNotContain(workflow, "APPLE_APP_PASSWORD")
        assertDoesNotContain(workflow, "APPLE_TEAM_ID")

        print("ForkPrereleaseWorkflowTests passed")
    }

    private static func assertContains(_ text: String, _ expected: String) {
        assert(text.contains(expected), "Expected workflow to contain \(expected)")
    }

    private static func assertDoesNotContain(_ text: String, _ unexpected: String) {
        assert(!text.contains(unexpected), "Expected workflow not to contain \(unexpected)")
    }
}
