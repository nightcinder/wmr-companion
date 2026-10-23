// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WMRCompanionProbe",
    platforms: [
        .iOS("18.0"),
        .macOS(.v12),
        .visionOS(.v1)
    ],
    products: [
        .library(
            name: "WMRCompanionProbe",
            targets: ["WMRCompanionProbe"]
        ),
    ],
    dependencies: [
        .package(path: "../../packages/WMRCompanionKit")
    ],
    targets: [
        .target(
            name: "WMRCompanionProbe",
            dependencies: [
                .product(name: "WMRCompanionKit", package: "WMRCompanionKit")
            ],
            path: "WMRCompanionProbe"
        ),
    ]
)
