// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MyAgent",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MyAgent", targets: ["MyAgent"])],
    targets: [
        .executableTarget(name: "MyAgent", path: "Sources/MyAgent"),
        .testTarget(name: "MyAgentTests", dependencies: ["MyAgent"], path: "Tests/MyAgentTests")
    ],
    swiftLanguageVersions: [.v5]
)
