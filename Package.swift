// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OpenClawWatchdog",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "OpenClawWatchdog", targets: ["OpenClawWatchdog"])
    ],
    targets: [
        .executableTarget(
            name: "OpenClawWatchdog",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
