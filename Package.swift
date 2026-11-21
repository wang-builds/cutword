// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CutWord",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(name: "CutWordCore", targets: ["CutWordCore"]),
        .executable(name: "cutword", targets: ["CutWordCLI"]),
        .executable(name: "CutWordApp", targets: ["CutWordApp"]),
    ],
    targets: [
        .target(
            name: "CutWordCore",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("Speech"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreImage"),
                .linkedFramework("AppKit"),
            ]
        ),
        .executableTarget(
            name: "CutWordCLI",
            dependencies: ["CutWordCore"]
        ),
        .executableTarget(
            name: "CutWordApp",
            dependencies: ["CutWordCore"],
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AVKit"),
                .linkedFramework("AppKit"),
            ]
        ),
        .testTarget(
            name: "CutWordTests",
            dependencies: ["CutWordCore"]
        ),
    ]
)
