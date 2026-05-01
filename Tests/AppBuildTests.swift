import Foundation

@main
struct AppBuildTests {
    static func main() {
        testQuillDevBundleIsDevelopmentBundle()
        testFreeFlowDevBundleIsNotDevelopmentBundle()
        print("AppBuildTests passed")
    }

    private static func testQuillDevBundleIsDevelopmentBundle() {
        assert(AppBuild.isDevBundleName("Quill Dev"))
    }

    private static func testFreeFlowDevBundleIsNotDevelopmentBundle() {
        assert(!AppBuild.isDevBundleName("FreeFlow Dev"))
    }
}
