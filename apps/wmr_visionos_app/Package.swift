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
        .library(
            name: "WMRVisionOSApp",
            targets: ["WMRVisionOSApp"]
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
        .target(
            name: "WMRVisionOSApp",
            dependencies: [
                "WMRVisionOSCore",
                .product(name: "WMRCompanionKit", package: "WMRCompanionKit")
            ],
            path: "Sources/WMRVisionOSApp",
            resources: [.copy("Resources")]
        ),
        .testTarget(
            name: "WMRVisionOSCoreTests",
            dependencies: ["WMRVisionOSCore"],
            path: "Tests/WMRVisionOSCoreTests"
        ),
        .testTarget(
            name: "WMRVisionOSAppTests",
            dependencies: ["WMRVisionOSApp"],
            path: "Tests/WMRVisionOSAppTests"
        ),
    ]
)
