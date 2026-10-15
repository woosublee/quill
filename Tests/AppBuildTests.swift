import Foundation

@main
struct AppBuildTests {
    static func main() {
        testQuillDevBundleIsDevelopmentBundle()
        testFreeFlowDevBundleIsNotDevelopmentBundle()
        testShortVersionUsesBundleValueAndNeverEmpty()
        print("AppBuildTests passed")
    }

    private static func testQuillDevBundleIsDevelopmentBundle() {
        assert(AppBuild.isDevBundleName("Quill Dev"))
    }

    private static func testFreeFlowDevBundleIsNotDevelopmentBundle() {
        assert(!AppBuild.isDevBundleName("FreeFlow Dev"))
    }

    private static func testShortVersionUsesBundleValueAndNeverEmpty() {
        assert(AppBuild.shortVersion(from: "1.1.0") == "1.1.0")
        assert(AppBuild.shortVersion(from: nil) == "unknown")
        assert(AppBuild.shortVersion(from: "") == "unknown")
        assert(AppBuild.shortVersion(from: 60) == "unknown")
    }
}
