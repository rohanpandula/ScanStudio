// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScanStudio",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "ScanStudioKit", targets: ["ScanStudioKit"]),
        .executable(name: "ScanStudio", targets: ["ScanStudio"]),
        .executable(name: "scanstudio-cli", targets: ["scanstudio-cli"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2")
    ],
    targets: [
        .target(
            name: "ScanStudioKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "ScanStudio",
            dependencies: ["ScanStudioKit"],
            // Packaging copies the icon resources directly into the app
            // bundle. Keeping SwiftPM's generated resource bundle out of the
            // executable avoids recording a builder-specific `.build` path.
            exclude: ["Resources"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "scanstudio-cli",
            dependencies: [
                "ScanStudioKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ScanStudioKitTests",
            dependencies: ["ScanStudioKit"],
            resources: [.process("Fixtures")]
        )
    ]
)
