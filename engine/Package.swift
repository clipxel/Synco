// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SyncEngine",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "SyncCore", swiftSettings: [.unsafeFlags(["-Ounchecked"])]),
        .executableTarget(name: "synccli", dependencies: ["SyncCore"]),
        .executableTarget(name: "SyncApp", dependencies: ["SyncCore"]),
    ]
)
