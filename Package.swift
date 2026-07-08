// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "QuotaRadar",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "QuotaRadarCore",
            targets: ["QuotaRadarCore"]
        ),
        .executable(
            name: "usage-radar",
            targets: ["UsageRadarCLI"]
        )
    ],
    targets: [
        .target(
            name: "QuotaRadarCore"
        ),
        .executableTarget(
            name: "UsageRadarCLI",
            dependencies: ["QuotaRadarCore"]
        ),
        .testTarget(
            name: "QuotaRadarCoreTests",
            dependencies: ["QuotaRadarCore"],
            resources: [
                .copy("Fixtures")
            ]
        )
    ]
)
