// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "PhotoEdit",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "SuiTone", targets: ["PhotoEdit"])],
    targets: [
        .executableTarget(name: "PhotoEdit", path: "Sources/PhotoEdit"),
        .testTarget(name: "PhotoEditTests", dependencies: ["PhotoEdit"], path: "Tests")
    ]
)
