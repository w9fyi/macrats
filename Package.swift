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
        .executable(
            name: "macrats-probe",
            targets: ["macrats-probe"]
        ),
        .executable(
            name: "macrats-chat",
            targets: ["macrats-chat"]
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
        .executableTarget(
            name: "macrats-probe",
            dependencies: ["MacRatsCore"]
        ),
        .executableTarget(
            name: "macrats-chat",
            dependencies: ["MacRatsCore"]
        ),
        .testTarget(
            name: "MacRatsCoreTests",
            dependencies: ["MacRatsCore"]
        ),
    ]
)
