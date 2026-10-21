// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "ClipShelf", platforms: [.macOS(.v14)],
    products: [.executable(name: "ClipShelf", targets: ["ClipShelf"])],
    targets: [
        .target(name: "ClipboardCore"),
        .executableTarget(name: "ClipShelf", dependencies: ["ClipboardCore"]),
        .testTarget(name: "ClipboardCoreTests", dependencies: ["ClipboardCore", "ClipShelf"])
    ]
)
