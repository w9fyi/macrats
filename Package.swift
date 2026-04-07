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
        .testTarget(
            name: "MacRatsCoreTests",
            dependencies: ["MacRatsCore"]
        ),
    ]
)
