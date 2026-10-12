// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "SoundRouter",
    platforms: [.macOS("14.2")],
    products: [
        .executable(name: "SoundRouter", targets: ["SoundRouter"]),
        .executable(name: "SoundRouterEngine", targets: ["SoundRouterEngine"]),
        .library(name: "SRCore", targets: ["SRCore"]),
        .library(name: "SoundRouterKit", targets: ["SoundRouterKit"]),
    ],
    targets: [
        // Real-time C core: ring buffers, drift resampler, mixer, meters, shm helpers.
        .target(
            name: "SRCore",
            cSettings: [.unsafeFlags(["-O3", "-std=c11", "-Wall", "-Wextra"])]
        ),
        // Shared Swift model, IPC contract and pure config logic.
        .target(name: "SoundRouterKit"),
        // Background LaunchAgent: capture, mix, write to driver, monitors, XPC service.
        .executableTarget(
            name: "SoundRouterEngine",
            dependencies: ["SRCore", "SoundRouterKit"],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AppKit"),
            ]
        ),
        // SwiftUI control application. Never touches audio streams.
        .executableTarget(
            name: "SoundRouter",
            dependencies: ["SoundRouterKit"],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(name: "SRCoreTests", dependencies: ["SRCore"]),
        .testTarget(name: "SoundRouterKitTests", dependencies: ["SoundRouterKit"]),
    ]
)
