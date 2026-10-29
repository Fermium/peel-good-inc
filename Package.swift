// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "labelize",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "labelize", targets: ["labelize"]),
        .library(name: "LabelKit", targets: ["LabelKit"]),
    ],
    targets: [
        .systemLibrary(name: "CCups", path: "Sources/CCups"),
        .target(name: "LabelKit", dependencies: ["CCups"]),
        .executableTarget(name: "labelize", dependencies: ["LabelKit"]),
        .executableTarget(name: "make-fixtures"),
        .executableTarget(name: "LabelizeApp", dependencies: ["LabelKit"]),
        .testTarget(name: "LabelKitTests", dependencies: ["LabelKit"]),
    ],
    swiftLanguageModes: [.v5]
)
