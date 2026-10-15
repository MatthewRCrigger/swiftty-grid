// swift-tools-version: 6.4
import PackageDescription

let core: [SwiftSetting] = [.enableExperimentalFeature("Lifetimes")]

let package = Package(
  name: "swiftty",
  // Deployment minimums for every included Apple product profile
  // (spec.roaming.md §2.1). Declarations are not proof of compatibility:
  // the watch companion links CompanionModel and MuxNavigation, and
  // SwifttyCore is not built for watchOS.
  platforms: [
    .macOS("27.0"), .iOS("27.0"), .macCatalyst("27.0"), .visionOS("27.0"),
    .tvOS("27.0"), .watchOS("27.0"),
  ],
  products: [
    .library(name: "SwifttyEngine", targets: ["SwifttyEngine"]),
    .library(name: "SwifttyCore", targets: ["SwifttyCore"]),
    .library(name: "SwifttyMobile", targets: ["SwifttyMobile"]),
    .library(name: "SwifttyMac", targets: ["SwifttyMac"]),
    .library(name: "SessionCore", targets: ["SessionCore"]),
    .library(name: "ScreenProtocol", targets: ["ScreenProtocol"]),
    .library(name: "SSHClient", targets: ["SSHClient"]),
    .library(name: "AppleTransport", targets: ["AppleTransport"]),
    .library(name: "TerminalHost", targets: ["TerminalHost"]),
    .library(name: "TerminalSurface", targets: ["TerminalSurface"]),
    .library(name: "CompanionModel", targets: ["CompanionModel"]),
    .library(name: "RoamingApp", targets: ["RoamingApp"]),
    .library(name: "MuxNavigation", targets: ["MuxNavigation"]),
    .library(name: "HostConnection", targets: ["HostConnection"]),
    .executable(name: "swiftty", targets: ["Swiftty"]),
    .executable(name: "swiftty-bench", targets: ["SwifttyBench"]),
    .executable(name: "swmux", targets: ["SwiftMuxCLI"]),
    .executable(name: "swiftmux-agent", targets: ["SwiftMuxAgent"]),
    .executable(name: "swmux-launcher", targets: ["SwiftMuxLauncher"]),
    .executable(name: "swiftmux-bench", targets: ["SwiftMuxBench"]),
    .executable(name: "swifttyd", targets: ["Swifttyd"]),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.86.0"),
    .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.11.0"),
    .package(
      url: "https://github.com/apple/swift-nio-transport-services.git",
      from: "1.25.0"
    ),
    .package(
      url: "https://github.com/apple/swift-crypto.git",
      "3.0.0" ..< "5.0.0"
    ),
    .package(
      url: "https://github.com/apple/swift-certificates.git",
      from: "1.10.0"
    ),
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
    // AppKit terminal view, embeddable by the native Mac client.
    .target(name: "SwifttyMac", dependencies: ["SwifttyCore"]),
    .executableTarget(
      name: "Swiftty",
      dependencies: [
        "SwifttyCore", "SwifttyMac", "SwiftMuxClient", "SwiftMuxBridge",
        "MuxNavigation", "MuxNavigationSMX", "HostConnection",
      ]
    ),
    // SwiftMux (spec.multiplexer.md): shared messages, engine bridge,
    // service, PTY launcher, client connection and frontends.
    .target(name: "SwiftMuxProtocol"),
    // OSC 7501 attention reducer (spec.inbox.md §3): pure, no I/O.
    .target(name: "MuxAttention", dependencies: ["SwiftMuxProtocol"]),
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
      dependencies: [
        "SwifttyEngine", "SwiftMuxProtocol", "SwiftMuxExport", "MuxAttention",
      ]
    ),
    // The one PTY owner: local XPC and, when configured, roaming RST/1.
    .executableTarget(
      name: "SwiftMuxAgent",
      dependencies: ["SwiftMuxService", "TerminalHost"]
    ),
    // Fresh-process terminal setup: login_tty, then exec the shell in place.
    .executableTarget(name: "SwiftMuxLauncher"),
    .target(name: "SwiftMuxClient", dependencies: ["SwiftMuxProtocol"]),
    // Deep links (spec.inbox.md §4): typed destinations, the
    // opaque locator, URL validation and the navigation state machine.
    // Foundation only, so the watch companion can link it.
    .target(
      name: "MuxNavigation",
      dependencies: ["SwiftMuxProtocol", "CompanionModel"]
    ),
    // The navigator's local SwiftMux (XPC) service adapter; macOS only.
    .target(
      name: "MuxNavigationSMX",
      dependencies: ["MuxNavigation", "SwiftMuxClient", "SwiftMuxProtocol"]
    ),
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
    ),
    .target(
      name: "TestSupport",
      dependencies: ["SessionCore"],
      path: "Tests/Support"
    ),
    .executableTarget(
      name: "StorageBoundsProbe",
      dependencies: ["SwifttyCore"],
      path: "Tests/StorageBoundsProbe",
      swiftSettings: core
    ),

    // MARK: Roaming SSH product (spec.roaming.md §11)

    // IDs, policies, lifecycle, input ledger, transfer manifests.
    // Foundation only; no terminal, network or UI code.
    .target(
      name: "SessionCore",
      dependencies: [.product(name: "Crypto", package: "swift-crypto")]
    ),
    // RST/1 messages, framing, snapshots, validation, bounded scheduler.
    .target(
      name: "ScreenProtocol",
      dependencies: ["SessionCore", "SwiftMuxProtocol"]
    ),
    // SSH authentication, host trust, exec, shell and the SFTP v3 client.
    .target(
      name: "SSHClient",
      dependencies: [
        "SessionCore", "ScreenProtocol",
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
        .product(name: "NIOSSH", package: "swift-nio-ssh"),
        .product(
          name: "NIOTransportServices",
          package: "swift-nio-transport-services"
        ), .product(name: "Crypto", package: "swift-crypto"),
      ]
    ),
    // Network framework QUIC, TLS identity and pinning policy.
    .target(
      name: "AppleTransport",
      dependencies: [
        "SessionCore", "ScreenProtocol",
        .product(name: "X509", package: "swift-certificates"),
        .product(name: "Crypto", package: "swift-crypto"),
      ]
    ),
    // RST/1 host over SwiftMux: grants, attachments, screen export and
    // bootstrap. Owns no PTYs; panes belong to the SwiftMux service.
    .target(
      name: "TerminalHost",
      dependencies: [
        "SessionCore", "ScreenProtocol", "AppleTransport", "SwifttyEngine",
        "SwiftMuxProtocol", "SwiftMuxService",
      ],
      swiftSettings: core
    ),
    // Shared direct-client frame/input abstraction and backends.
    .target(
      name: "TerminalSurface",
      dependencies: [
        "SessionCore", "ScreenProtocol", "AppleTransport", "SSHClient",
        "SwifttyCore", .product(name: "NIOCore", package: "swift-nio"),
      ],
      swiftSettings: core
    ),
    // Bounded watch/iPhone status DTOs; no SSH/RST secrets, no Swiftty.
    .target(name: "CompanionModel"),
    // Pairing-code descriptor and Bonjour discovery contract shared by the
    // native Mac exporter and the direct-client importer
    // (spec.connection-setup.md). Foundation only: no UI, credentials,
    // PTYs or network I/O.
    .target(name: "HostConnection"),
    // Shared app model and per-platform UI for the direct clients
    // (Apps/* app targets are thin XcodeGen wrappers around this).
    .target(
      name: "RoamingApp",
      dependencies: [
        "SessionCore", "ScreenProtocol", "SSHClient", "TerminalSurface",
        "CompanionModel", "SwifttyCore", "SwifttyMobile", "MuxNavigation",
        "HostConnection",
        // AppKit surface for the native Mac client only; never Catalyst.
        .target(name: "SwifttyMac", condition: .when(platforms: [.macOS])),
        .product(name: "Crypto", package: "swift-crypto"),
      ],
      path: "Apps/Shared",
      swiftSettings: core
    ),
    // The fixed no-PTY SSH bootstrap helper; relays to the service.
    .executableTarget(
      name: "Swifttyd",
      dependencies: ["TerminalHost", "SessionCore", "ScreenProtocol"],
      path: "Apps/swifttyd",
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
        "SwiftMuxClient", "SwiftMuxTerminal", "SwifttyCore", "MuxAttention",
        "TestSupport",
      ]
    ),
    .testTarget(
      name: "MuxNavigationTests",
      dependencies: [
        "MuxNavigation", "MuxNavigationSMX", "SwiftMuxProtocol",
        "CompanionModel", "SwiftMuxClient", "SwiftMuxService", "TestSupport",
      ]
    ),
    .testTarget(name: "HostConnectionTests", dependencies: ["HostConnection"]),
    .testTarget(
      name: "MuxAttentionTests",
      dependencies: ["MuxAttention", "SwiftMuxProtocol"]
    ),
    .testTarget(
      name: "SwifttyAppTests",
      dependencies: [
        "Swiftty", "SwifttyMac", "SwifttyCore", "TestSupport",
        "SwiftMuxService", "SwiftMuxClient", "SwiftMuxProtocol",
        "SwiftMuxExport", "MuxNavigation", "MuxNavigationSMX", "HostConnection",
      ]
    ),
    .testTarget(
      name: "ProtocolTests",
      dependencies: [
        "SessionCore", "ScreenProtocol", "CompanionModel", "TestSupport",
      ]
    ),
    .testTarget(
      name: "IntegrationTests",
      dependencies: [
        "SessionCore", "ScreenProtocol", "SSHClient", "AppleTransport",
        "TerminalHost", "TerminalSurface", "SwifttyCore", "TestSupport",
        "RoamingApp", "SwiftMuxProtocol", "SwiftMuxService", "SwiftMuxClient",
        "HostConnection", "MuxNavigation",
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
        .product(name: "NIOSSH", package: "swift-nio-ssh"),
        .product(name: "Crypto", package: "swift-crypto"),
      ],
      swiftSettings: core
    ),
  ],
)
