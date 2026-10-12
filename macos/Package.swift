// swift-tools-version: 6.0
import PackageDescription
import Foundation

let nativeCoreLibrary = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("photon-ffi/target/release").path
let nativeCoreLink: [LinkerSetting] = [.unsafeFlags(["-L", nativeCoreLibrary])]

let package = Package(
    name: "Photon",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "PhotonRenderSurface", targets: ["PhotonRenderSurface"]),
        .executable(name: "Photon", targets: ["PhotonApp"]),
        .library(name: "PhotonUI", targets: ["PhotonUI"]),
        .executable(name: "PhotonCoreCheck", targets: ["PhotonCoreCheck"]),
    ],
    dependencies: [
        // Engine lives in its own package so its manifest and the app's stay
        // independently owned. Additive dependency, no rewrite.
        .package(path: "../engine"),
        .package(path: "../photon-ffi"),
    ],
    targets: [
        .target(name: "PhotonUI"),
        .target(
            name: "PhotonRenderSurface",
            dependencies: ["PhotonUI", .product(name: "PhotonRender", package: "engine")]
        ),
        .executableTarget(name: "PhotonApp", dependencies: [
            "PhotonUI", "PhotonRenderSurface", .product(name: "PhotonCoreBridge", package: "photon-ffi"),
        ], linkerSettings: nativeCoreLink),
        .executableTarget(name: "PhotonCoreCheck", dependencies: [
            .product(name: "PhotonCoreBridge", package: "photon-ffi"),
        ], linkerSettings: nativeCoreLink),
        .testTarget(name: "PhotonUITests", dependencies: ["PhotonUI"]),
    ]
)
