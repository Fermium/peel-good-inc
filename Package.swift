// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "peelgood",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "peelgood", targets: ["peelgood"]),
        .library(name: "LabelKit", targets: ["LabelKit"]),
        .library(name: "PeelGoodCore", targets: ["PeelGoodCore"]),
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
        .target(name: "PeelGoodCore", dependencies: ["LabelKit", "PeelGoodShared"]),
        // The command line's one description (commands, help, completions, man page), shared with Settings > CLI.
        .target(name: "PeelGoodCLI", dependencies: ["LabelKit", "PeelGoodCore", "PeelGoodShared"]),
        .executableTarget(name: "peelgood", dependencies: ["LabelKit", "PeelGoodCLI", "PeelGoodCore", "PeelGoodShared"]),
        .executableTarget(name: "make-fixtures"),
        .executableTarget(name: "PeelGoodApp", dependencies: [
            "LabelKit",
            "PeelGoodCLI",
            "PeelGoodCore",
            "PeelGoodShared",
            .product(name: "Hummingbird", package: "hummingbird"),
            .product(name: "MCP", package: "swift-sdk"),
            .product(name: "HTTPTypes", package: "swift-http-types"),
            .product(name: "Logging", package: "swift-log"),
        ]),
        .executableTarget(name: "peel-good-mcp", dependencies: ["PeelGoodShared"]),
        .testTarget(name: "LabelKitTests", dependencies: ["LabelKit"]),
        .testTarget(name: "PeelGoodCoreTests", dependencies: ["PeelGoodCore", "LabelKit", "PeelGoodShared"]),
        .testTarget(name: "PeelGoodCLITests", dependencies: ["PeelGoodCLI", "LabelKit", "PeelGoodCore"]),
        .testTarget(name: "PeelGoodAppTests", dependencies: ["PeelGoodApp", "PeelGoodCore", "LabelKit", .product(name: "MCP", package: "swift-sdk")]),
    ],
    swiftLanguageModes: [.v5]
)
