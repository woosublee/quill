// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "QuillSparkleDependencies",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "SparkleResolver", targets: ["SparkleResolver"])
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
        )
    ]
)
