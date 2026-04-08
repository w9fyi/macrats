// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MacRatsCore",
    platforms: [
        .macOS(.v14)
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
        .executable(
            name: "macrats",
            targets: ["macrats"]
        ),
    ],
    targets: [
        .target(
            name: "MacRatsCore",
            linkerSettings: [
                // libz is required by FileTransferSession for raw zlib
                // compress/decompress that matches Python's
                // zlib.compress byte-for-byte. macOS ships libz with
                // the SDK at /usr/lib/libz.dylib; this just adds -lz
                // to the link line.
                .linkedLibrary("z")
            ]
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
        .executableTarget(
            name: "macrats",
            dependencies: ["MacRatsCore"]
        ),
        .testTarget(
            name: "MacRatsCoreTests",
            dependencies: ["MacRatsCore"]
        ),
    ]
)
