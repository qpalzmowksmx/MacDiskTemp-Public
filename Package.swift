// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacDiskTemp",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "MacDiskTemp", targets: ["MacDiskTemp"]),
        .executable(name: "diskprobe", targets: ["DiskProbe"])
    ],
    targets: [
        .target(name: "DiskCore"),
        .target(name: "AlertCore", dependencies: ["DiskCore"]),
        .target(name: "MacAlertSupport", dependencies: ["AlertCore"]),
        .executableTarget(name: "MacDiskTemp", dependencies: ["DiskCore", "AlertCore", "MacAlertSupport"]),
        .executableTarget(name: "AlertHarness", dependencies: ["AlertCore", "MacAlertSupport"]),
        .executableTarget(name: "DiskProbe", dependencies: ["DiskCore"]),
        .testTarget(name: "DiskCoreTests", dependencies: ["DiskCore"]),
        .testTarget(name: "AlertCoreTests", dependencies: ["AlertCore"])
    ],
    swiftLanguageModes: [.v5]
)
