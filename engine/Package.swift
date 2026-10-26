// swift-tools-version:5.9
import PackageDescription

// The app (SyncApp) is macOS only. The engine and the command line build on macOS,
// Windows and Linux; off macOS the engine uses pocketfft and a bundled ffmpeg.
var targets: [Target] = [
    .target(name: "PocketFFT", cSettings: [.unsafeFlags(["-O3"])]),
    .target(name: "SyncCore", dependencies: ["PocketFFT"], swiftSettings: [.unsafeFlags(["-Ounchecked"])]),
    .executableTarget(name: "synccli", dependencies: ["SyncCore"]),
]
#if os(macOS)
targets.append(.executableTarget(name: "SyncApp", dependencies: ["SyncCore"]))
#endif

let package = Package(
    name: "SyncEngine",
    platforms: [.macOS(.v13)],
    targets: targets
)
