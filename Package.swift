// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MacRatsCore",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "MacRatsCore",
            targets: ["MacRatsCore"]
        ),
        .executable(
            name: "macrats-sniff",
            targets: ["macrats-sniff"]
        ),
    ],
    targets: [
        .target(
            name: "MacRatsCore"
        ),
        .executableTarget(
            name: "macrats-sniff",
            dependencies: ["MacRatsCore"]
        ),
        .testTarget(
            name: "MacRatsCoreTests",
            dependencies: ["MacRatsCore"]
        ),
    ]
)
