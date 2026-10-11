import Foundation
import SwiftMuxProtocol

/// Registration of the bundled agent (SMAppService in the app; fakes in
/// tests). Each call completes only when the operation has.
public protocol AgentRegistration: Sendable {
  func unregister() async throws
  func register() async throws
}

/// Spec §8: staged updates and the ordered empty-state barrier.
///
/// Staging records a new bundle without changing admission. Installing
/// quiesces the service, ends workspaces with normal bounded termination
/// (only if the user chose to), waits for the barrier, awaits
/// unregistration, replaces the bundle, registers the new service and
/// verifies that a new instance answers. Cancelling before unregistration
/// restores normal admission. Nothing is sequenced by sleeping alone; the
/// barrier is polled from service status.
public actor UpdateCoordinator {
  public enum Phase: Equatable, Sendable {
    case idle
    case staged(URL)
    case quiescing
    case awaitingBarrier
    case unregistering
    case replacing
    case registering
    case verifying
    case finished(newServer: ServerInstanceID)
    case cancelled
    case failed(String)
  }

  public typealias Connect = @Sendable () async throws -> MuxConnection
  public typealias Replace = @Sendable (URL) async throws -> Void

  public private(set) var phase: Phase = .idle
  private let connect: Connect
  private let registration: any AgentRegistration
  private let replace: Replace
  private var cancelRequested = false
  public var barrierTimeout: Duration = .seconds(30)

  public init(
    connect: @escaping Connect,
    registration: any AgentRegistration,
    replace: @escaping Replace
  ) {
    self.connect = connect
    self.registration = registration
    self.replace = replace
  }

  /// Records a new bundle. Admission and running sessions are unchanged.
  public func stage(_ bundle: URL) { phase = .staged(bundle) }

  /// Requests cancellation; honoured only before unregistration.
  public func cancel() { cancelRequested = true }

  /// Installs the staged bundle. With `endWorkspaces` false the update
  /// waits for the user to end sessions; with true it ends them.
  @discardableResult
  public func install(endWorkspaces: Bool) async -> Phase {
    guard case let .staged(bundle) = phase else {
      return fail("no staged update")
    }
    cancelRequested = false
    let connection: MuxConnection
    let oldServer: ServerInstanceID
    do {
      connection = try await connect()
      guard let welcome = await connection.welcome else {
        return fail("service did not identify itself")
      }
      oldServer = welcome.server
      phase = .quiescing
      try await connection.execute(.quiesce(true))
      if endWorkspaces { try await connection.execute(.endAllWorkspaces) }
      phase = .awaitingBarrier
      let deadline = ContinuousClock.now + barrierTimeout
      while true {
        if cancelRequested {
          _ = try? await connection.execute(.quiesce(false))
          await connection.close()
          phase = .cancelled
          return phase
        }
        guard case let .status(status) = try await connection.execute(.status)
        else { return fail("unexpected status reply") }
        if status.workspaces == 0, status.panes == 0, !status.attached { break }
        guard ContinuousClock.now < deadline else {
          _ = try? await connection.execute(.quiesce(false))
          return fail(
            "\(status.workspaces) workspace(s) still running; end them or choose “End workspaces and update”"
          )
        }
        try await Task.sleep(for: .milliseconds(100))
      }
      await connection.close()
    } catch { return fail("\(error)") }
    // Past this point cancellation no longer restores admission.
    do {
      phase = .unregistering
      try await registration.unregister()
      phase = .replacing
      try await replace(bundle)
      phase = .registering
      try await registration.register()
      phase = .verifying
      let fresh = try await connect()
      defer { Task { await fresh.close() } }
      guard let welcome = await fresh.welcome, welcome.server != oldServer,
        SMX.compatibleVersions.contains(welcome.protocolVersion)
      else { return fail("the updated service did not start") }
      phase = .finished(newServer: welcome.server)
      return phase
    } catch { return fail("\(error)") }
  }

  private func fail(_ message: String) -> Phase {
    phase = .failed(message)
    return phase
  }
}
