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
        .executableTarget(name: "MacDiskTemp", dependencies: ["DiskCore"]),
        .executableTarget(name: "DiskProbe", dependencies: ["DiskCore"]),
        .testTarget(name: "DiskCoreTests", dependencies: ["DiskCore"])
    ],
    swiftLanguageModes: [.v5]
)
