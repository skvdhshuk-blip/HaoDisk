// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HaoDiskCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "HaoDiskCore", targets: ["HaoDiskCore"])],
    targets: [
        .target(name: "HaoDiskCore", path: "HaoDisk/Core"),
        .testTarget(name: "HaoDiskTests", dependencies: ["HaoDiskCore"], path: "HaoDiskTests")
    ]
)
