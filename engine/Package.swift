// swift-tools-version: 6.0
import PackageDescription
import Foundation

// photon-ffi is a staticlib; the executables that link it need its search path.
// The library target only needs the C header, which comes with the package.
let nativeCoreLibrary = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("photon-ffi/target/release").path
let nativeCoreLink: [LinkerSetting] = [.unsafeFlags(["-L", nativeCoreLibrary])]

let package = Package(
    name: "PhotonEngine",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PhotonRender", targets: ["PhotonRender"]),
        .executable(name: "PhotonEngineDemo", targets: ["PhotonEngineDemo"]),
        .executable(name: "PhotonVerify", targets: ["PhotonVerify"]),
    ],
    dependencies: [
        // DXV decode lives in photon-core, reached through the C ABI. It is
        // pure portable CPU work that the Windows shell will share; writing it
        // Swift-side would mean writing it twice.
        .package(path: "../photon-ffi"),
    ],
    targets: [
        .target(name: "PhotonRender", dependencies: [
            .product(name: "PhotonFFI", package: "photon-ffi"),
        ]),
        .executableTarget(name: "PhotonEngineDemo", dependencies: ["PhotonRender"],
                          linkerSettings: nativeCoreLink),
        .executableTarget(name: "PhotonVerify", dependencies: ["PhotonRender"],
                          linkerSettings: nativeCoreLink),
    ]
)
