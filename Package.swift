// swift-tools-version: 6.4
import PackageDescription

let core: [SwiftSetting] = [.enableExperimentalFeature("Lifetimes")]

let package = Package(
  name: "swiftty",
  platforms: [
    .macOS("27.0"), .iOS("27.0"), .macCatalyst("27.0"), .visionOS("27.0"),
  ],
  products: [
    .library(name: "SwifttyEngine", targets: ["SwifttyEngine"]),
    .library(name: "SwifttyCore", targets: ["SwifttyCore"]),
    .library(name: "SwifttyMobile", targets: ["SwifttyMobile"]),
    .executable(name: "swiftty", targets: ["Swiftty"]),
    .executable(name: "swiftty-bench", targets: ["SwifttyBench"]),
    .executable(name: "swmux", targets: ["SwiftMuxCLI"]),
    .executable(name: "swiftmux-agent", targets: ["SwiftMuxAgent"]),
    .executable(name: "swmux-launcher", targets: ["SwiftMuxLauncher"]),
    .executable(name: "swiftmux-bench", targets: ["SwiftMuxBench"]),
  ],
  targets: [
    // Headless terminal engine: parser, state, history, input encoding
    // and PTY processes. No Metal, fonts or AppKit; the SwiftMux service
    // links only this.
    .target(name: "SwifttyEngine", swiftSettings: core),
    .target(
      name: "SwifttyCore",
      dependencies: ["SwifttyEngine"],
      resources: [.copy("Renderer/Shaders.metal")],
      swiftSettings: core,
    ),
    // Test/bench-only allocation counter built on libmalloc's logger hook.
    .target(name: "CAllocCounter"),
    .executableTarget(
      name: "Swiftty",
      dependencies: ["SwifttyCore", "SwiftMuxClient", "SwiftMuxBridge"]
    ),
    // SwiftMux (spec.multiplexer.md): shared messages, engine bridge,
    // service, PTY launcher, client connection and frontends.
    .target(name: "SwiftMuxProtocol"),
    // Frame export needs only the engine; import needs the renderer.
    .target(
      name: "SwiftMuxExport",
      dependencies: ["SwifttyEngine", "SwiftMuxProtocol"]
    ),
    .target(
      name: "SwiftMuxBridge",
      dependencies: ["SwifttyCore", "SwiftMuxProtocol", "SwiftMuxExport"]
    ),
    // Headless: links the engine, never the Metal renderer or fonts.
    .target(
      name: "SwiftMuxService",
      dependencies: ["SwifttyEngine", "SwiftMuxProtocol", "SwiftMuxExport"]
    ),
    .executableTarget(name: "SwiftMuxAgent", dependencies: ["SwiftMuxService"]),
    // Fresh-process terminal setup: login_tty, then exec the shell in place.
    .executableTarget(name: "SwiftMuxLauncher"),
    .target(name: "SwiftMuxClient", dependencies: ["SwiftMuxProtocol"]),
    // §10 measurements: throughput, latency, CPU, memory, export and GPU.
    .executableTarget(
      name: "SwiftMuxBench",
      dependencies: [
        "SwiftMuxService", "SwiftMuxClient", "SwiftMuxProtocol",
        "SwiftMuxBridge", "SwifttyCore",
      ]
    ),
    .target(
      name: "SwiftMuxTerminal",
      dependencies: ["SwiftMuxClient", "SwiftMuxProtocol"]
    ),
    .executableTarget(
      name: "SwiftMuxCLI",
      dependencies: ["SwiftMuxTerminal", "SwiftMuxClient", "SwiftMuxProtocol"]
    ),
    // UIKit views are conditional; shared frontend tests also run on macOS.
    .target(name: "SwifttyMobile", dependencies: ["SwifttyCore"]),
    .executableTarget(
      name: "SwifttyBench",
      dependencies: ["SwifttyCore", "CAllocCounter"],
      swiftSettings: core,
    ), .target(name: "TestSupport", path: "Tests/Support"),
    .executableTarget(
      name: "StorageBoundsProbe",
      dependencies: ["SwifttyCore"],
      path: "Tests/StorageBoundsProbe",
      swiftSettings: core
    ),
    .testTarget(
      name: "SwifttyCoreTests",
      dependencies: [
        "SwifttyCore", "SwifttyEngine", "CAllocCounter", "TestSupport",
        "StorageBoundsProbe",
      ],
      swiftSettings: core,
    ),
    .testTarget(
      name: "SwifttyMobileTests",
      dependencies: ["SwifttyMobile", "SwifttyCore", "TestSupport"],
      resources: [.copy("Fixtures")],
    ),
    .testTarget(
      name: "SwiftMuxTests",
      dependencies: [
        "SwiftMuxProtocol", "SwiftMuxBridge", "SwiftMuxService",
        "SwiftMuxClient", "SwiftMuxTerminal", "SwifttyCore",
      ]
    ),
    .testTarget(
      name: "SwifttyAppTests",
      dependencies: [
        "Swiftty", "SwifttyCore", "TestSupport", "SwiftMuxService",
        "SwiftMuxClient", "SwiftMuxProtocol",
      ]
    ),
  ],
)
