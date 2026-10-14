@testable import AppleTransport
import Dispatch
import Network
import SessionCore
import SwifttyCore
import Synchronization
import TerminalSurface
import Testing

private final class SurfaceCallbackOwner: Sendable {
  let release: @Sendable () -> Void
  init(release: @escaping @Sendable () -> Void) { self.release = release }

  deinit { release() }
}

@Suite(.serialized, .timeLimit(.minutes(1)))
struct SurfaceCallbackLifetimeTests {
  typealias Callback = @Sendable () -> Void
  enum SSHField: CaseIterable, Sendable { case lifecycle, refusal }
  enum RoamingField: CaseIterable, Sendable {
    case lifecycle, status, invalidate
  }
  enum LocalField: CaseIterable, Sendable { case lifecycle, event }
  enum QUICField: CaseIterable, Sendable {
    case viability, betterPath, terminated
  }

  private static func forward<Value: Sendable>(
    _ callback: Callback?
  ) -> (@Sendable (Value) -> Void)? {
    guard let callback else { return nil }
    return { _ in callback() }
  }

  private func verifyReplacement(
    install: @escaping @Sendable (Callback?) -> Void,
    read: @escaping @Sendable () -> Void,
    invoke: () -> Void,
  ) {
    let released = Mutex(false)
    let replacementCalls = Mutex(0)
    func attach() {
      let owner = SurfaceCallbackOwner {
        read()
        install { replacementCalls.withLock { $0 += 1 } }
        released.withLock { $0 = true }
      }
      install { withExtendedLifetime(owner) {} }
    }
    attach()
    install(nil)
    #expect(released.withLock { $0 })
    invoke()
    #expect(replacementCalls.withLock { $0 } == 1)
    install(nil)
  }

  @Test(arguments: SSHField.allCases)
  func sshReplacementReleasesOutsideLock(field: SSHField) {
    let backend = SSHStreamBackend(
      channel: FakeByteChannel(),
      session: TerminalSession(),
    )
    verifyReplacement(
      install: { callback in
        switch field {
        case .lifecycle: backend.onLifecycleChange = Self.forward(callback)
        case .refusal: backend.onInputRefusal = Self.forward(callback)
        }
      },
      read: { _ = backend.lifecycle },
      invoke: {
        switch field {
        case .lifecycle: backend.onLifecycleChange?(.active)
        case .refusal: backend.onInputRefusal?(.backpressure)
        }
      }
    )
  }

  @Test(arguments: QUICField.allCases)
  func quicReplacementReleasesOutsideLock(field: QUICField) {
    let group = NWConnectionGroup(
      with: NWMultiplexGroup(to: .hostPort(host: "127.0.0.1", port: 9)),
      using: NWParameters(quic: NWProtocolQUIC.Options(alpn: ["rst/1"])),
    )
    let connection = QUICRSTConnection(
      role: .server,
      group: group,
      queue: DispatchQueue(label: "callback-lifetime"),
    )
    defer { connection.close() }
    verifyReplacement(
      install: { callback in
        switch field {
        case .viability: connection.onViabilityChange = Self.forward(callback)
        case .betterPath: connection.onBetterPath = Self.forward(callback)
        case .terminated: connection.setOnTerminated(callback ?? {})
        }
      },
      read: { _ = connection.isClosed },
      invoke: {
        switch field {
        case .viability: connection.onViabilityChange?(true)
        case .betterPath: connection.onBetterPath?(true)
        case .terminated: connection.close()
        }
      }
    )
  }

  @Test(arguments: RoamingField.allCases)
  func roamingReplacementReleasesOutsideLock(field: RoamingField) throws {
    let host = try FakeHost()
    let backend = RoamingScreenBackend(
      bootstrapper: FakeBootstrapper(host: host),
      connector: FakeConnector(host: host),
    )
    verifyReplacement(
      install: { callback in
        switch field {
        case .lifecycle: backend.onLifecycleChange = Self.forward(callback)
        case .status: backend.onStatus = Self.forward(callback)
        case .invalidate: backend.onInvalidate = callback
        }
      },
      read: {
        _ = backend.lifecycle
        _ = backend.currentFrame()
      },
      invoke: {
        switch field {
        case .lifecycle: backend.onLifecycleChange?(.active)
        case .status: backend.onStatus?(RoamingStatus(state: .idle))
        case .invalidate: backend.onInvalidate?()
        }
      }
    )
  }

  #if os(macOS) && !targetEnvironment(macCatalyst)
  @Test(arguments: LocalField.allCases)
  func localReplacementReleasesOutsideLock(field: LocalField) {
    let backend = LocalPTYBackend()
    verifyReplacement(
      install: { callback in
        switch field {
        case .lifecycle: backend.onLifecycleChange = Self.forward(callback)
        case .event: backend.onEvent = Self.forward(callback)
        }
      },
      read: { _ = backend.lifecycle },
      invoke: {
        switch field {
        case .lifecycle: backend.onLifecycleChange?(.active)
        case .event: backend.onEvent?(.bell)
        }
      }
    )
  }
  #endif
}
