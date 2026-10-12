// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PhotonEngine",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PhotonRender", targets: ["PhotonRender"]),
        .executable(name: "PhotonEngineDemo", targets: ["PhotonEngineDemo"]),
        .executable(name: "PhotonVerify", targets: ["PhotonVerify"]),
    ],
    targets: [
        .target(name: "PhotonRender"),
        .executableTarget(name: "PhotonEngineDemo", dependencies: ["PhotonRender"]),
        .executableTarget(name: "PhotonVerify", dependencies: ["PhotonRender"]),
    ]
)
