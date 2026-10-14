import Foundation
import MuxNavigation
import SwiftMuxClient
import SwiftMuxProtocol

/// Activates a pane on behalf of `SMXAttentionService`, for frontends
/// whose interactive lease lives on another connection (the native
/// workspace window owns its own).
public protocol AttentionPaneOpener: Sendable {
  func open(
    _ target: PaneTarget,
    takeover expectedLease: UInt64?
  ) async throws(AttentionServiceError)
}

/// `AttentionService` over a local SwiftMux XPC connection. The XPC peer
/// check and service handshake are the authentication (step 3); every
/// metadata call is lease-free.
public actor SMXAttentionService: AttentionService {
  public let connection: MuxConnection
  private let opener: (any AttentionPaneOpener)?

  /// `opener` handles step 5; without one, this connection attaches
  /// (or explicitly takes over) and activates the pane itself.
  public init(
    connection: MuxConnection,
    opener: (any AttentionPaneOpener)? = nil
  ) {
    self.connection = connection
    self.opener = opener
  }

  public func serviceEpoch() async throws(AttentionServiceError)
    -> ServerInstanceID
  {
    guard let welcome = await connection.welcome else {
      throw .offline("SwiftMux service not connected.")
    }
    return welcome.server
  }

  public func locate(
    _ reference: AttentionReference
  ) async throws(AttentionServiceError) -> AttentionLocation {
    guard
      case let .attention(location) = try await run(.locateAttention(reference))
    else { throw .other("unexpected reply") }
    return location
  }

  public func leaseState(
    of workspace: WorkspaceID
  ) async throws(AttentionServiceError) -> LeaseState {
    guard case let .workspaces(list) = try await run(.listWorkspaces) else {
      throw .other("unexpected reply")
    }
    guard let summary = list.first(where: { $0.id == workspace }) else {
      throw .notFound
    }
    return LeaseState(
      generation: summary.leaseGeneration,
      holder: summary.leaseHolder
    )
  }

  public func open(
    _ target: PaneTarget,
    takeover expectedLease: UInt64?
  ) async throws(AttentionServiceError) {
    guard !Task.isCancelled else { throw .other("Opening was cancelled.") }
    if let opener {
      try await opener.open(target, takeover: expectedLease)
      return
    }
    let selector = WorkspaceSelector.id(target.workspace)
    if let expectedLease {
      try await run(.takeover(selector, expectedLease: expectedLease))
    } else {
      try await run(.attach(AttachRequest(selector)))
    }
    if let tab = target.tab { try await run(.selectTab(tab)) }
    try await run(.focusPane(target.pane))
  }

  public func markSeen(
    _ reference: AttentionReference
  ) async throws(AttentionServiceError) { try await run(.markSeen(reference)) }

  public func close() async { await connection.close() }

  @discardableResult
  private func run(
    _ command: MuxCommand
  ) async throws(AttentionServiceError) -> MuxReply {
    guard !Task.isCancelled else { throw .other("The request was cancelled.") }
    do { return try await connection.execute(command) } catch let error
      as MuxError
    { throw Self.map(error) } catch { throw .other(String(describing: error)) }
  }

  /// SMX error codes as navigation outcomes.
  public static func map(_ error: MuxError) -> AttentionServiceError {
    switch error.code {
    case .connectionLost, .quiescing: .offline(error.description)
    case .serverInstanceChanged: .serviceRestarted
    case .notFound: .notFound
    case .leaseHeld: .leaseHeld
    case .staleRevision: .leaseChanged
    case .paneExited: .paneExited
    case .unauthorized: .unauthorized
    case .invalidRequest, .incompatibleVersion: .unsupported(error.description)
    default: .other(error.description)
    }
  }
}

/// Connects to the local SwiftMux service for every configured host it
/// represents (the native app has exactly one: this Mac).
public struct SMXAttentionConnector: AttentionServiceConnector {
  public typealias Connect = @Sendable () async throws -> MuxConnection
  private let connect: Connect
  private let opener: (any AttentionPaneOpener)?

  public init(
    opener: (any AttentionPaneOpener)? = nil,
    connect: @escaping Connect
  ) {
    self.connect = connect
    self.opener = opener
  }

  public func connect(
    to host: NavigationHost
  ) async throws(AttentionServiceError) -> any AttentionService {
    do {
      return SMXAttentionService(
        connection: try await connect(),
        opener: opener
      )
    } catch let error as MuxError { throw SMXAttentionService.map(error) } catch
    { throw .offline(String(describing: error)) }
  }
}
