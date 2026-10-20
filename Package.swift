// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "bmonitor",
    platforms: [.macOS(.v15)],
    dependencies: [
        // Atualização automática fora da App Store.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .systemLibrary(name: "CSRT", pkgConfig: "srt", providers: [.brew(["srt"])]),
        .target(name: "MonitorCore", dependencies: ["CSRT"]),
        .executableTarget(
            name: "bmonitor", dependencies: ["MonitorCore", .product(name: "Sparkle", package: "Sparkle")]),
        .executableTarget(name: "latency-probe", dependencies: ["MonitorCore"]),
        .testTarget(
            name: "MonitorCoreTests", dependencies: ["MonitorCore"],
            resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v5]
)
