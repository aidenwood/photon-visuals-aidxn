// swift-tools-version: 6.0
import PackageDescription

// C import surface only. The consuming executable supplies the static-library
// search path; this dependency has no unsafe SwiftPM build flags.
let package = Package(
    name: "PhotonFFI",
    products: [
        .library(name: "PhotonFFI", targets: ["PhotonFFI"]),
        .library(name: "PhotonCoreBridge", targets: ["PhotonCoreBridge"]),
    ],
    targets: [
        .systemLibrary(name: "PhotonFFI", path: "include"),
        .target(name: "PhotonCoreBridge", dependencies: ["PhotonFFI"]),
    ]
)
