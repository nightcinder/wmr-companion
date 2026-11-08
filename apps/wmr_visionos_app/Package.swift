// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WMRVisionOSApp",
    platforms: [
        .visionOS(.v1),
        .iOS("18.0"),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "WMRVisionOSCore",
            targets: ["WMRVisionOSCore"]
        ),
    ],
    dependencies: [
        .package(path: "../../packages/WMRCompanionKit")
    ],
    targets: [
        .target(
            name: "WMRVisionOSCore",
            dependencies: [
                .product(name: "WMRCompanionKit", package: "WMRCompanionKit")
            ],
            path: "Sources/WMRVisionOSCore"
        ),
        .testTarget(
            name: "WMRVisionOSCoreTests",
            dependencies: ["WMRVisionOSCore"],
            path: "Tests/WMRVisionOSCoreTests"
        ),
    ]
)
