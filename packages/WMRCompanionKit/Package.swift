// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WMRCompanionKit",
    platforms: [
        .iOS(.v14),
        .macOS(.v12),
        .visionOS(.v1)
    ],
    products: [
        .library(
            name: "WMRCompanionKit",
            targets: ["WMRCompanionKit"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "WMRCompanionKit",
            dependencies: [],
            path: "Sources/WMRCompanionKit"
        ),
        .testTarget(
            name: "WMRCompanionKitTests",
            dependencies: ["WMRCompanionKit"],
            path: "Tests/WMRCompanionKitTests"
        ),
    ]
)
