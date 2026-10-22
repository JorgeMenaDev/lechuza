// swift-tools-version:6.0
import PackageDescription

// lechuza-engine: the native helper the Electron app spawns. It records
// meetings (microphone + system audio), mixes them and transcribes them with
// Parakeet, speaking JSON lines on stdio. The logic lives in the
// LechuzaEngine library so tests can reach it; the executable is a thin loop.
let package = Package(
    name: "lechuza-engine",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "lechuza-engine", targets: ["lechuza-engine"])
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", .upToNextMinor(from: "0.15.5"))
    ],
    targets: [
        .target(
            name: "LechuzaEngine",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
        ),
        .executableTarget(
            name: "lechuza-engine",
            dependencies: ["LechuzaEngine"]
        ),
        .testTarget(
            name: "LechuzaEngineTests",
            dependencies: ["LechuzaEngine"]
        ),
    ]
)
