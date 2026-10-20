// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "bmonitor",
    platforms: [.macOS(.v15)],
    targets: [
        .systemLibrary(name: "CSRT", pkgConfig: "srt", providers: [.brew(["srt"])]),
        .target(name: "MonitorCore", dependencies: ["CSRT"]),
        .executableTarget(name: "bmonitor", dependencies: ["MonitorCore"]),
        .executableTarget(name: "latency-probe", dependencies: ["MonitorCore"]),
        .testTarget(
            name: "MonitorCoreTests", dependencies: ["MonitorCore"],
            resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v5]
)
