#if os(macOS)
import Dispatch
import Foundation
import SessionCore
import SwiftMuxProtocol
import SwiftMuxService
import Synchronization

/// An SMX client of the in-process SwiftMux service: hello, numbered
/// requests, sequenced input and events. Every callback runs on `queue`.
///
/// The roaming host owns no PTYs; it reaches panes only through this, so
/// remote attachments get the same leases, takeover fencing and input
/// ledger as the native frontend.
final class MuxLocalSession: @unchecked Sendable {
  typealias EventHandler = (MuxEvent) -> Void

  let queue: DispatchQueue
  private var connection: MuxLocalConnection?
  private var nextRequest: UInt64 = 1
  private var requests: [UInt64: (MuxResult) -> Void] = [:]
  private var nextInput: UInt64 = 1
  private var inputs: [UInt64: (MuxError?) -> Void] = [:]
  private var closed = false
  /// Set on `queue` before any message is expected.
  var onEvent: EventHandler?
  var onPaneChanged: ((PaneID) -> Void)?
  var onClosed: ((String) -> Void)?
  private(set) var welcome: Welcome?

  init(queue: DispatchQueue) { self.queue = queue }

  /// Connects and says hello; requests may be issued immediately after.
  func connect(to service: MuxService, frontend: FrontendKind, remote: Bool) {
    dispatchPrecondition(condition: .onQueue(queue))
    let sink = LocalClientSink(
      onMessage: { [weak self] message in
        self?.queue.async { self?.receive(message) }
      },
      onPaneChanged: { [weak self] pane in
        self?.queue.async { self?.onPaneChanged?(pane) }
      },
      onClosed: { [weak self] reason in
        self?.queue.async { self?.finish(reason) }
      }
    )
    let connection = service.connectLocal(remote: remote, sink: sink)
    self.connection = connection
    connection.send(.hello(Hello(frontend: frontend)))
  }

  func request(
    _ command: MuxCommand,
    _ completion: @escaping (MuxResult) -> Void
  ) {
    dispatchPrecondition(condition: .onQueue(queue))
    guard let connection, !closed else {
      return completion(.failure(MuxError(.connectionLost)))
    }
    let id = nextRequest
    nextRequest += 1
    requests[id] = completion
    connection.send(.request(id: id, command: command))
  }

  func request(_ command: MuxCommand) async -> MuxResult {
    await withCheckedContinuation { continuation in
      queue.async {
        self.request(command) { continuation.resume(returning: $0) }
      }
    }
  }

  /// Input sequences restart at one for each attachment.
  func resetInput() { nextInput = 1 }

  func input(
    _ payload: InputPayload,
    attachment: AttachmentID,
    pane: PaneID,
    _ completion: @escaping (MuxError?) -> Void
  ) {
    dispatchPrecondition(condition: .onQueue(queue))
    guard let connection, !closed else {
      return completion(MuxError(.connectionLost))
    }
    let sequence = nextInput
    nextInput += 1
    inputs[sequence] = completion
    connection.send(
      .input(
        InputRecord(
          sequence: sequence,
          attachment: attachment,
          pane: pane,
          payload: payload
        )
      )
    )
  }

  /// Releases any lease held through this session. Pending callbacks
  /// complete with `connectionLost`.
  func close() {
    dispatchPrecondition(condition: .onQueue(queue))
    connection?.close()
    connection = nil
    finish("closed")
  }

  private func receive(_ message: ServerMessage) {
    switch message {
    case let .welcome(w): welcome = w
    case let .rejected(error): finish("rejected: \(error)")
    case let .reply(id, result): requests.removeValue(forKey: id)?(result)
    case let .inputAck(sequence, error):
      inputs.removeValue(forKey: sequence)?(error)
    case let .event(event): onEvent?(event)
    }
  }

  private func finish(_ reason: String) {
    guard !closed else { return }
    closed = true
    let lost = MuxError(.connectionLost, reason)
    let pendingRequests = requests.values
    let pendingInputs = inputs.values
    requests = [:]
    inputs = [:]
    for callback in pendingRequests { callback(.failure(lost)) }
    for callback in pendingInputs { callback(lost) }
    onClosed?(reason)
  }
}

// MARK: Identity mapping

extension SessionID {
  /// RST/1 session identifiers are SwiftMux workspace identities.
  init(_ workspace: WorkspaceID) {
    self.init(bytes: workspace.rawValue.bytes)!
  }

  var workspace: WorkspaceID { WorkspaceID(rawValue: UUID(bytes: bytes)) }
}

extension SessionCore.ServerInstanceID {
  /// The one service epoch: the SwiftMux service instance.
  init(_ instance: SwiftMuxProtocol.ServerInstanceID) {
    self.init(bytes: instance.rawValue.bytes)!
  }
}

extension UUID {
  var bytes: [UInt8] { withUnsafeBytes(of: uuid) { Array($0) } }

  init(bytes: [UInt8]) {
    precondition(bytes.count == 16)
    var value = UUID().uuid
    withUnsafeMutableBytes(of: &value) { $0.copyBytes(from: bytes) }
    self.init(uuid: value)
  }
}
#endif
