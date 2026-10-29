// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "labelize",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "labelize", targets: ["labelize"]),
        .library(name: "LabelKit", targets: ["LabelKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.28.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1"),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    ],
    targets: [
        .systemLibrary(name: "CCups", path: "Sources/CCups"),
        .target(name: "LabelKit", dependencies: ["CCups"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .executableTarget(name: "labelize", dependencies: ["LabelKit"]),
        .executableTarget(name: "make-fixtures"),
        .executableTarget(name: "LabelizeApp", dependencies: [
            "LabelKit",
            .product(name: "Hummingbird", package: "hummingbird"),
            .product(name: "MCP", package: "swift-sdk"),
            .product(name: "HTTPTypes", package: "swift-http-types"),
            .product(name: "Logging", package: "swift-log"),
        ]),
        .executableTarget(name: "labelize-mcp"),
        .testTarget(name: "LabelKitTests", dependencies: ["LabelKit"]),
        .testTarget(name: "LabelizeAppTests", dependencies: ["LabelizeApp", .product(name: "MCP", package: "swift-sdk")]),
    ],
    swiftLanguageModes: [.v5]
)
