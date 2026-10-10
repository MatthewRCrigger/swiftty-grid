import Dispatch
import Foundation
import SwiftMuxProtocol

/// The single concrete connection to the SwiftMux service.
///
/// Exactly one bounded event consumer (`nextEvent`). Frames are delivered
/// one per pane at a time: the service sends the next only after this
/// connection acknowledges the previous, which happens when the consumer
/// takes it. Nothing is replayed after connection loss.
public actor MuxConnection {
  public nonisolated let queue: DispatchSerialQueue
  public nonisolated var unownedExecutor: UnownedSerialExecutor {
    queue.asUnownedSerialExecutor()
  }

  private let channel: SMXChannel
  public private(set) var welcome: Welcome?
  public private(set) var attachment: AttachmentID?
  private var nextRequest: UInt64 = 1
  private var nextInput: UInt64 = 1
  private var nextPaste: UInt64 = 1
  private var requests: [UInt64: CheckedContinuation<MuxReply, any Error>] = [:]
  private var inputs: [UInt64: (MuxError?) -> Void] = [:]
  private var callbacks: [UInt64: (Result<MuxReply, MuxError>) -> Void] = [:]
  private var handshake: CheckedContinuation<Welcome, any Error>?
  private var events: [MuxEvent] = []
  private var eventHead = 0
  private var waiter: CheckedContinuation<MuxEvent?, any Error>?
  private var closedError: MuxError?
  private var isClosed = false
  private var closedDeliberately = false

  /// Non-frame events held for the consumer before the connection fails.
  public static let maxBufferedEvents = 4096

  private init(channel: SMXChannel, queue: DispatchSerialQueue) {
    self.channel = channel
    self.queue = queue
  }

  /// Connects to the launchd service and performs the handshake.
  public static func connect(
    machService name: String = ProcessInfo.processInfo.environment[
      "SWMUX_SERVICE"
    ] ?? SMX.defaultMachService,
    frontend: FrontendKind,
    terminalProfile: String? = nil
  ) async throws -> MuxConnection {
    let queue = DispatchSerialQueue(
      label: "swiftmux.client",
      qos: .userInitiated
    )
    let channel = SMXChannel.connect(machService: name, queue: queue)
    return try await start(channel, queue, frontend, terminalProfile)
  }

  /// Connects to an in-process anonymous listener (tests).
  public static func connect(
    endpoint: SMXEndpoint,
    frontend: FrontendKind,
    terminalProfile: String? = nil
  ) async throws -> MuxConnection {
    let queue = DispatchSerialQueue(
      label: "swiftmux.client",
      qos: .userInitiated
    )
    let channel = SMXChannel.connect(endpoint: endpoint, queue: queue)
    return try await start(channel, queue, frontend, terminalProfile)
  }

  private static func start(
    _ channel: SMXChannel,
    _ queue: DispatchSerialQueue,
    _ frontend: FrontendKind,
    _ profile: String?
  ) async throws -> MuxConnection {
    let connection = MuxConnection(channel: channel, queue: queue)
    try await connection.open(
      Hello(frontend: frontend, terminalProfile: profile)
    )
    return connection
  }

  private func open(_ hello: Hello) async throws {
    channel.activate { [weak self] event in
      self?.assumeIsolated { $0.receive(event) }
    }
    // A peer the service refuses (for example, a different signing team)
    // gets no reply; fail the handshake instead of waiting forever.
    let timeout = queue
    let deadline = Self.handshakeTimeout
    timeout.asyncAfter(deadline: .now() + deadline) { [weak self] in
      self?
        .assumeIsolated { connection in
          guard connection.handshake != nil else { return }
          connection.fail(
            MuxError(
              .connectionLost,
              "the service did not answer; it may be signed by a different team or not running"
            )
          )
          connection.channel.cancel()
        }
    }
    let welcome = try await withCheckedThrowingContinuation { continuation in
      handshake = continuation
      transmit(.hello(hello))
    }
    self.welcome = welcome
  }

  public static let handshakeTimeout: TimeInterval = 5

  // MARK: Receiving

  private func receive(_ event: SMXChannel.Event) {
    switch event {
    case let .closed(reason): fail(MuxError(.connectionLost, reason))
    case let .message(data):
      let message: ServerMessage
      do {
        message = try SMXCodec.decode(
          ServerMessage.self,
          from: data,
          limit: SMXCodec.serverRecordLimit(welcome?.limits ?? .standard)
        )
      } catch {
        fail(error)
        channel.cancel()
        return
      }
      dispatch(message)
    }
  }

  private func dispatch(_ message: ServerMessage) {
    switch message {
    case let .welcome(w):
      handshake?.resume(returning: w)
      handshake = nil
    case let .rejected(error):
      if let handshake {
        handshake.resume(throwing: error)
        self.handshake = nil
      } else {
        deliver(.detached(reason: "rejected: \(error)"))
      }
    case let .reply(id, result):
      if case let .success(.attached(attachment, _)) = result {
        // Input sequences are per attachment and start at 1.
        self.attachment = attachment
        nextInput = 1
      }
      if let callback = callbacks.removeValue(forKey: id) {
        switch result {
        case let .success(reply): callback(.success(reply))
        case let .failure(error): callback(.failure(error))
        }
        return
      }
      guard let c = requests.removeValue(forKey: id) else { return }
      switch result {
      case let .success(reply): c.resume(returning: reply)
      case let .failure(error): c.resume(throwing: error)
      }
    case let .inputAck(sequence, error):
      inputs.removeValue(forKey: sequence)?(error)
    case let .event(event):
      if case .detached = event { attachment = nil }
      deliver(event)
    }
  }

  private func deliver(_ event: MuxEvent) {
    if let waiter {
      self.waiter = nil
      take(event)
      waiter.resume(returning: event)
      return
    }
    guard events.count - eventHead < Self.maxBufferedEvents else {
      fail(MuxError(.resourceLimit, "event consumer is not keeping up"))
      channel.cancel()
      return
    }
    events.append(event)
  }

  /// Acknowledges a frame or inbox update once the consumer has it.
  private func take(_ event: MuxEvent) {
    switch event {
    case let .frame(frame):
      transmit(
        .frameAck(pane: frame.identity.pane, revision: frame.identity.revision)
      )
    case let .inbox(update): transmit(.inboxAck(revision: update.revision))
    default: break
    }
  }

  private func fail(_ error: MuxError) {
    guard !isClosed else { return }
    isClosed = true
    closedError = error
    attachment = nil
    handshake?.resume(throwing: error)
    handshake = nil
    failPending(error)
    if let waiter {
      self.waiter = nil
      waiter.resume(throwing: error)
    }
  }

  private func failPending(_ error: MuxError) {
    for c in requests.values { c.resume(throwing: error) }
    requests = [:]
    for c in callbacks.values { c(.failure(error)) }
    callbacks = [:]
    for c in inputs.values { c(error) }
    inputs = [:]
  }

  // MARK: Public API

  /// The next event, or nil after a deliberate `close`.
  public func nextEvent() async throws -> MuxEvent? {
    if eventHead < events.count {
      let event = events[eventHead]
      eventHead += 1
      if eventHead == events.count {
        events.removeAll(keepingCapacity: true)
        eventHead = 0
      }
      take(event)
      return event
    }
    if isClosed {
      if closedDeliberately { return nil }
      throw closedError ?? MuxError(.connectionLost)
    }
    precondition(waiter == nil, "MuxConnection supports one event consumer")
    return try await withCheckedThrowingContinuation { waiter = $0 }
  }

  /// Executes a command. Acknowledgement means the operation committed.
  @discardableResult
  public func execute(_ command: MuxCommand) async throws -> MuxReply {
    if let closedError { throw closedError }
    let id = nextRequest
    nextRequest += 1
    return try await withCheckedThrowingContinuation { continuation in
      requests[id] = continuation
      transmit(.request(id: id, command: command))
    }
  }

  /// Sends semantic input; returns once admitted to the pane's writer.
  public func send(_ input: MuxInput, to pane: PaneID) async throws {
    try await submit(pane, .input(input))
  }

  /// Sends input without waiting for admission. Errors are dropped; the
  /// caller keeps order because records are sent in call order.
  public func post(_ input: MuxInput, to pane: PaneID) {
    guard let attachment, closedError == nil else { return }
    let sequence = nextInput
    nextInput += 1
    transmit(
      .input(
        InputRecord(
          sequence: sequence,
          attachment: attachment,
          pane: pane,
          payload: .input(input)
        )
      )
    )
  }

  /// Sends one record with a caller-chosen sequence and waits for its
  /// acknowledgement (ledger tests); does not advance `nextInput`.
  package func submit(raw record: InputRecord) async throws {
    if let closedError { throw closedError }
    try await withCheckedThrowingContinuation {
      (c: CheckedContinuation<Void, any Error>) in
      inputs[record.sequence] = { error in
        if let error { c.resume(throwing: error) } else { c.resume() }
      }
      transmit(.input(record))
    }
  }

  private func submit(_ pane: PaneID, _ payload: InputPayload) async throws {
    if let closedError { throw closedError }
    guard let attachment else { throw MuxError(.notAttached) }
    let sequence = nextInput
    nextInput += 1
    try await withCheckedThrowingContinuation {
      (c: CheckedContinuation<Void, any Error>) in
      inputs[sequence] = { error in
        if let error { c.resume(throwing: error) } else { c.resume() }
      }
      transmit(
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
  }

  // MARK: Ordered, non-awaiting submission
  //
  // Calls made in order from one thread reach the service in that order:
  // each hops onto this connection's serial queue synchronously in
  // FIFO order before transmitting.

  /// Sends input; admission errors go to `rejected`, if given.
  public nonisolated func enqueue(
    _ input: MuxInput,
    to pane: PaneID,
    rejected: (@Sendable (MuxError) -> Void)? = nil
  ) {
    queue.async {
      self.assumeIsolated { connection in
        guard let attachment = connection.attachment,
          connection.closedError == nil
        else {
          rejected?(connection.closedError ?? MuxError(.notAttached))
          return
        }
        let sequence = connection.nextInput
        connection.nextInput += 1
        if let rejected {
          connection.inputs[sequence] = { if let e = $0 { rejected(e) } }
        }
        connection.transmit(
          .input(
            InputRecord(
              sequence: sequence,
              attachment: attachment,
              pane: pane,
              payload: .input(input)
            )
          )
        )
      }
    }
  }

  /// Executes a command in call order; `completion` runs on this
  /// connection's queue.
  public nonisolated func enqueue(
    _ command: MuxCommand,
    completion: (@Sendable (Result<MuxReply, MuxError>) -> Void)? = nil
  ) {
    queue.async {
      self.assumeIsolated { connection in
        if let error = connection.closedError {
          completion?(.failure(error))
          return
        }
        let id = connection.nextRequest
        connection.nextRequest += 1
        connection.callbacks[id] = { completion?($0) }
        connection.transmit(.request(id: id, command: command))
      }
    }
  }

  /// Starts a paste in call order: its begin record precedes any later
  /// enqueued input, which the service defers until the envelope closes.
  public nonisolated func enqueuePaste(
    _ text: String,
    to pane: PaneID,
    completion: (@Sendable (Result<PasteState, MuxError>) -> Void)? = nil
  ) {
    queue.async {
      self.assumeIsolated { connection in
        let limits = connection.welcome?.limits ?? .standard
        guard let attachment = connection.attachment,
          connection.closedError == nil
        else {
          completion?(
            .failure(connection.closedError ?? MuxError(.notAttached))
          )
          return
        }
        guard text.utf8.count <= limits.maxPasteBytes else {
          completion?(
            .failure(
              MuxError(
                .resourceLimit,
                "paste exceeds \(limits.maxPasteBytes) bytes"
              )
            )
          )
          return
        }
        let id = connection.nextPaste
        connection.nextPaste += 1
        let sequence = connection.nextInput
        connection.nextInput += 1
        connection.transmit(
          .input(
            InputRecord(
              sequence: sequence,
              attachment: attachment,
              pane: pane,
              payload: .pasteBegin(id: id)
            )
          )
        )
        Task {
          let result = await connection.pasteBody(
            id: id,
            text: text,
            pane: pane
          )
          completion?(result)
        }
      }
    }
  }

  private func pasteBody(
    id: UInt64,
    text: String,
    pane: PaneID
  ) async -> Result<PasteState, MuxError> {
    let limits = welcome?.limits ?? .standard
    var sent = 0
    for chunk in Self.chunks(text, maxBytes: limits.maxPasteChunkBytes) {
      var attempts = 0
      while true {
        do {
          try await submit(pane, .pasteChunk(id: id, text: chunk))
          break
        } catch let error as MuxError
          where error.code == .resourceLimit
          && error.message.contains("buffer is full")
          && attempts < pasteRetry.attempts
        {
          attempts += 1
          try? await Task.sleep(for: pasteRetry.delay)
        } catch {
          // Close the envelope on the service: an open paste would keep
          // deferring this pane's later input and refuse a new paste.
          try? await submit(pane, .pasteCancel(id: id))
          return .success(sent > 0 ? .partial : .aborted)
        }
      }
      sent += chunk.utf8.count
    }
    do { try await submit(pane, .pasteEnd(id: id)) } catch {
      return .failure(error as? MuxError ?? MuxError(.connectionLost))
    }
    return .success(.completed)
  }

  /// How long a paste waits for writer credit before giving up.
  private var pasteRetry: (attempts: Int, delay: Duration) = (
    200, .milliseconds(25)
  )

  /// Shortens the paste retry budget (tests).
  package func setPasteRetry(attempts: Int, delay: Duration) {
    pasteRetry = (attempts, delay)
  }

  /// Pastes in bounded chunks admitted under writer credit, waiting while
  /// the pane's writer is full. Never replays after connection loss.
  public func paste(_ text: String, to pane: PaneID) async throws -> PasteState
  {
    let limits = welcome?.limits ?? .standard
    guard text.utf8.count <= limits.maxPasteBytes else {
      throw MuxError(
        .resourceLimit,
        "paste exceeds \(limits.maxPasteBytes) bytes"
      )
    }
    let id = nextPaste
    nextPaste += 1
    try await submit(pane, .pasteBegin(id: id))
    return try await pasteBody(id: id, text: text, pane: pane).get()
  }

  /// Splits on scalar boundaries so each chunk is valid UTF-8.
  static func chunks(_ text: String, maxBytes: Int) -> [String] {
    var out: [String] = []
    var current = String.UnicodeScalarView()
    var bytes = 0
    for scalar in text.unicodeScalars {
      let n = UTF8.width(scalar)
      if bytes + n > maxBytes, !current.isEmpty {
        out.append(String(current))
        current = String.UnicodeScalarView()
        bytes = 0
      }
      current.append(scalar)
      bytes += n
    }
    if !current.isEmpty { out.append(String(current)) }
    return out
  }

  /// Releases the attachment, bounded in time; panes keep running.
  public func detach() async {
    guard attachment != nil, closedError == nil else { return }
    let task = Task { try? await self.execute(.detach) }
    let timeout = Task {
      try? await Task.sleep(for: .seconds(2))
      task.cancel()
    }
    _ = await task.value
    timeout.cancel()
    attachment = nil
  }

  /// Closes the connection. An attached lease is released by the service.
  public func close() {
    guard !isClosed else { return }
    channel.cancel()
    isClosed = true
    closedDeliberately = true
    let error = MuxError(.connectionLost, "closed")
    failPending(error)
    if let waiter {
      self.waiter = nil
      waiter.resume(returning: nil)
    }
  }

  private func transmit(_ message: ClientMessage) {
    do {
      channel.send(
        try SMXCodec.encode(
          message,
          limit: SMXCodec.clientRecordLimit(welcome?.limits ?? .standard)
        )
      )
    } catch { fail(error) }
  }
}
