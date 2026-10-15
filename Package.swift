// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Cortex",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "CortexApp", targets: ["CortexApp"]),
        .executable(name: "cortex", targets: ["CortexCLI"]),
    ],
    targets: [
        .target(name: "CortexKit"),
        .executableTarget(name: "CortexApp", dependencies: ["CortexKit"]),
        .executableTarget(name: "CortexCLI", dependencies: ["CortexKit"]),
        .testTarget(name: "CortexKitTests", dependencies: ["CortexKit"]),
    ],
    swiftLanguageModes: [.v5]
)
