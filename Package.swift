// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "QuillSparkleDependencies",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [
        .executable(name: "SparkleResolver", targets: ["SparkleResolver"]),
        // Shared with the iPhone app, which depends on this repository for it
        // (#634). The Mac app builds it from the Makefile instead.
        .library(name: "QuillNoteSyncCore", targets: ["QuillNoteSyncCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.2")
    ],
    targets: [
        .executableTarget(
            name: "SparkleResolver",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "BuildSupport/SparkleResolver"
        ),
        .target(
            name: "QuillNoteSyncCore",
            path: "Packages/QuillNoteSyncCore/Sources"
        )
    ]
)
