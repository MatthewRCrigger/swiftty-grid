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
  /// Checks the artifact after the empty-state barrier. Asynchronous
  /// validators should honour task cancellation before unregistration.
  public typealias Validate = @Sendable (URL) async throws -> Void

  public private(set) var phase: Phase = .idle
  private let connect: Connect
  private let registration: any AgentRegistration
  private let replace: Replace
  private let validate: Validate
  private var cancelRequested = false
  private var installing = false
  private var cancelPendingWait: (@Sendable () -> Void)?
  /// Shared budget from quiescing through acceptance of the empty-state
  /// barrier, starting after connection establishment. Rollback has its
  /// own two-second command wait.
  public var barrierTimeout: Duration = .seconds(30)

  public init(
    connect: @escaping Connect,
    registration: any AgentRegistration,
    replace: @escaping Replace,
    validate: @escaping Validate = { _ in }
  ) {
    self.connect = connect
    self.registration = registration
    self.replace = replace
    self.validate = validate
  }

  /// Records a new bundle while no install is running. Admission and
  /// running sessions are unchanged.
  public func stage(_ bundle: URL) {
    guard !installing else { return }
    phase = .staged(bundle)
  }

  /// Requests cancellation; honoured only before unregistration.
  public func cancel() {
    cancelRequested = true
    cancelPendingWait?()
  }

  /// Installs the staged bundle. With `endWorkspaces` false the update
  /// waits for the user to end sessions; with true it ends them.
  @discardableResult
  public func install(endWorkspaces: Bool) async -> Phase {
    guard !installing else { return phase }
    guard case let .staged(bundle) = phase else {
      return fail("no staged update")
    }
    installing = true
    defer { installing = false }
    cancelRequested = false
    let connection: MuxConnection
    let oldServer: ServerInstanceID
    var pendingConnection: MuxConnection?
    var quiesceRequested = false
    do {
      try checkCancellation()
      connection = try await waitFor(
        { [connect] in try await connect() },
        discard: { await $0.close() }
      )
      pendingConnection = connection
      try checkCancellation()
      guard let welcome = await connection.welcome else {
        await connection.close()
        return fail("service did not identify itself")
      }
      oldServer = welcome.server
      let deadline = ContinuousClock.now + barrierTimeout
      phase = .quiescing
      // A cancelled wait can still leave this command committed.
      quiesceRequested = true
      guard
        case .ok = try await executeBeforeBarrier(
          .quiesce(true),
          connection: connection,
          deadline: deadline
        )
      else { throw MuxError(.invalidRequest, "unexpected quiesce reply") }
      if endWorkspaces {
        guard
          case .ok = try await executeBeforeBarrier(
            .endAllWorkspaces,
            connection: connection,
            deadline: deadline
          )
        else {
          throw MuxError(.invalidRequest, "unexpected end-workspaces reply")
        }
      }
      phase = .awaitingBarrier
      while true {
        if cancelRequested || Task.isCancelled {
          await restoreAdmissionAndClose(connection)
          phase = .cancelled
          return phase
        }
        guard
          case let .status(status) = try await executeBeforeBarrier(
            .status,
            connection: connection,
            deadline: deadline
          )
        else {
          await restoreAdmissionAndClose(connection)
          return fail("unexpected status reply")
        }
        guard status.server == oldServer else {
          throw MuxError(
            .invalidRequest,
            "status identified a different service"
          )
        }
        guard status.quiescing else {
          throw MuxError(
            .invalidRequest,
            "service resumed admission before the update barrier"
          )
        }
        if status.workspaces == 0, status.panes == 0, !status.attached { break }
        guard ContinuousClock.now < deadline else {
          await restoreAdmissionAndClose(connection)
          return fail(
            "\(status.workspaces) workspace(s) still running; end them or choose “End workspaces and update”"
          )
        }
        try await Task.sleep(
          for: min(.milliseconds(100), deadline - ContinuousClock.now)
        )
      }
      try await waitFor { [validate] in try await validate(bundle) }
      try checkCancellation()
    } catch {
      if let pendingConnection {
        if quiesceRequested {
          await restoreAdmissionAndClose(pendingConnection)
        } else {
          await pendingConnection.close()
        }
      }
      if error is CancellationError || Task.isCancelled || cancelRequested {
        phase = .cancelled
        return phase
      }
      return fail("\(error)")
    }
    // Keep the control connection available for rollback until this
    // boundary. No suspension separates the final cancellation check
    // from starting unregistration.
    phase = .unregistering
    // Once committed, keep the transaction owned independently of caller
    // cancellation through replacement, registration and verification.
    return await beginCommit(
      bundle: bundle,
      connection: connection,
      oldServer: oldServer
    )
    .value
  }

  private func beginCommit(
    bundle: URL,
    connection: MuxConnection,
    oldServer: ServerInstanceID
  ) -> Task<Phase, Never> {
    Task {
      do {
        try await registration.unregister()
        await connection.close()
        phase = .replacing
        try await replace(bundle)
        phase = .registering
        try await registration.register()
        phase = .verifying
        let fresh = try await connect()
        let welcome = await fresh.welcome
        // Retire the verification channel within the owned transaction
        // before publishing either its success or its failure.
        await fresh.close()
        guard let welcome, welcome.server != oldServer,
          SMX.compatibleVersions.contains(welcome.protocolVersion)
        else { return commitFailure("the updated service did not start") }
        phase = .finished(newServer: welcome.server)
        return phase
      } catch {
        await connection.close()
        return commitFailure("\(error)")
      }
    }
  }

  private func executeBeforeBarrier(
    _ command: MuxCommand,
    connection: MuxConnection,
    deadline: ContinuousClock.Instant
  ) async throws -> MuxReply {
    try checkCancellation()
    let remaining = deadline - ContinuousClock.now
    guard remaining > .zero else {
      throw MuxError(.connectionLost, "update barrier timed out")
    }
    let reply = try await waitFor {
      try await connection.execute(command, timeout: remaining)
    }
    // A reply can race a queued timer callback. Check the absolute
    // deadline before allowing it to advance the update transaction.
    guard ContinuousClock.now < deadline else {
      throw MuxError(.connectionLost, "update barrier timed out")
    }
    return reply
  }

  /// One pre-unregistration wait is active at a time. Both the public
  /// cancel action and parent task cancellation reach the owned worker.
  private func waitFor<Value: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Value,
    discard: @escaping @Sendable (Value) async -> Void = { _ in }
  ) async throws -> Value {
    try checkCancellation()
    let worker = Task { try await operation() }
    cancelPendingWait = { worker.cancel() }
    defer { cancelPendingWait = nil }
    let value = try await withTaskCancellationHandler {
      try await worker.value
    } onCancel: {
      worker.cancel()
    }
    do { try checkCancellation() } catch {
      // A connector may return a live connection despite cancellation.
      // Release that result before propagating the cancelled wait.
      await discard(value)
      throw error
    }
    return value
  }

  private func checkCancellation() throws {
    try Task.checkCancellation()
    if cancelRequested { throw CancellationError() }
  }

  private func commitFailure(_ message: String) -> Phase {
    let step: String
    switch phase {
    case .unregistering: step = "unregistration"
    case .replacing: step = "replacement"
    case .registering: step = "registration"
    case .verifying: step = "verification"
    default: step = "commit"
    }
    return fail("Update failed during \(step): \(message)")
  }

  private func fail(_ message: String) -> Phase {
    phase = .failed(message)
    return phase
  }

  /// Rollback must run even when the install task was cancelled. A
  /// separate task lets the bounded command wait for its acknowledgement.
  private func restoreAdmissionAndClose(_ connection: MuxConnection) async {
    await Task.detached {
      _ = try? await connection.execute(.quiesce(false), timeout: .seconds(2))
      await connection.close()
    }
    .value
  }
}
