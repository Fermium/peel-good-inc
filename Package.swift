// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "peelgood",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "peelgood", targets: ["peelgood"]),
        .library(name: "LabelKit", targets: ["LabelKit"]),
        .library(name: "LabelizeCore", targets: ["LabelizeCore"]),
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
        // Names, paths and server.json, with no dependencies: the MCP relay and the Share extension use it too.
        .target(name: "PeelGoodShared"),
        // What the app, the API and the CLI share: settings, printer choice, option overrides, rules, tags,
        // history and limits. Foundation, CoreGraphics and LabelKit only (no AppKit or SwiftUI).
        .target(name: "LabelizeCore", dependencies: ["LabelKit", "PeelGoodShared"]),
        // The command line's one description (commands, help, completions, man page), shared with Settings > CLI.
        .target(name: "LabelizeCLI", dependencies: ["LabelKit", "LabelizeCore", "PeelGoodShared"]),
        .executableTarget(name: "peelgood", dependencies: ["LabelKit", "LabelizeCLI", "LabelizeCore", "PeelGoodShared"]),
        .executableTarget(name: "make-fixtures"),
        .executableTarget(name: "LabelizeApp", dependencies: [
            "LabelKit",
            "LabelizeCLI",
            "LabelizeCore",
            "PeelGoodShared",
            .product(name: "Hummingbird", package: "hummingbird"),
            .product(name: "MCP", package: "swift-sdk"),
            .product(name: "HTTPTypes", package: "swift-http-types"),
            .product(name: "Logging", package: "swift-log"),
        ]),
        .executableTarget(name: "peel-good-mcp", dependencies: ["PeelGoodShared"]),
        .testTarget(name: "LabelKitTests", dependencies: ["LabelKit"]),
        .testTarget(name: "LabelizeCoreTests", dependencies: ["LabelizeCore", "LabelKit", "PeelGoodShared"]),
        .testTarget(name: "LabelizeCLITests", dependencies: ["LabelizeCLI", "LabelKit", "LabelizeCore"]),
        .testTarget(name: "LabelizeAppTests", dependencies: ["LabelizeApp", "LabelizeCore", "LabelKit", .product(name: "MCP", package: "swift-sdk")]),
    ],
    swiftLanguageModes: [.v5]
)
