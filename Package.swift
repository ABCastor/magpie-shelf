// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Magpie",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.4"),
    ],
    targets: [
        .executableTarget(
            name: "Magpie",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/Magpie",
            // The .icns and Assets.car are consumed only by the packaged .app bundle (copied
            // by scripts/build-dmg.sh). Excluding it here keeps SwiftPM
            // quiet and avoids embedding it in the SPM module's bundle.
            exclude: ["Resources/AppIcon.icns", "Resources/Assets.car"],
            resources: [
                .process("Resources"),
            ]
        ),
        .testTarget(
            name: "MagpieTests",
            dependencies: ["Magpie"],
            path: "Tests/MagpieTests"
        ),
    ]
)
