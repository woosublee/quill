// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QuillSparkleDependencies",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .executable(name: "SparkleResolver", targets: ["SparkleResolver"]),
        // Shared with the iPhone app, which depends on this repository for it
        // (#634). The Mac app builds it from the Makefile instead.
        .library(name: "QuillNoteSyncCore", targets: ["QuillNoteSyncCore"]),
        .library(name: "QuillAITextCore", targets: ["QuillAITextCore"]),
        .library(name: "QuillUserIssueCore", targets: ["QuillUserIssueCore"]),
        .library(name: "QuillSummaryFormatCore", targets: ["QuillSummaryFormatCore"]),
        .library(name: "QuillSummaryGenerationCore", targets: ["QuillSummaryGenerationCore"]),
        .library(name: "QuillProviderCore", targets: ["QuillProviderCore"]),
        .library(name: "QuillAudioLevelCore", targets: ["QuillAudioLevelCore"])
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
            path: "Packages/QuillNoteSyncCore/Sources",
            // The Makefile builds it with -swift-version 6 too.
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "QuillAITextCore",
            path: "Packages/QuillAITextCore/Sources",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "QuillUserIssueCore",
            path: "Packages/QuillUserIssueCore/Sources",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "QuillSummaryFormatCore",
            dependencies: ["QuillAITextCore", "QuillUserIssueCore"],
            path: "Packages/QuillSummaryFormatCore/Sources",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "QuillSummaryGenerationCore",
            dependencies: ["QuillAITextCore", "QuillUserIssueCore", "QuillSummaryFormatCore"],
            path: "Packages/QuillSummaryGenerationCore/Sources",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "QuillProviderCore",
            path: "Packages/QuillProviderCore/Sources",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "QuillAudioLevelCore",
            path: "Packages/QuillAudioLevelCore/Sources",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ],
    swiftLanguageModes: [.v5]
)
