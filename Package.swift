// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Flow",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Flow", targets: ["Flow"])],
    targets: [
        .target(name: "FlowCore"),
        .executableTarget(name: "Flow", dependencies: ["FlowCore"]),
        .executableTarget(name: "FlowChecks", dependencies: ["FlowCore"], path: "Tests/FlowCoreChecks")
    ]
)
