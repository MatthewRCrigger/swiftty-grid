import Dispatch
import Foundation
import SwiftMuxProtocol

extension Duration {
  fileprivate var timeInterval: TimeInterval {
    let (seconds, attoseconds) = components
    return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
  }
}

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
  private var channelCancelled = false
  /// Panes with a paste envelope open, each with the pastes (and the
  /// input enqueued after them) waiting for it to close: one paste per
  /// pane at a time, in call order.
  private var pasting: [PaneID: [PaneJob]] = [:]
  /// The service's refusal of a paste's begin record, by paste id.
  private var pasteRefusals: [UInt64: MuxError] = [:]

  private enum PaneJob {
    case input(MuxInput, rejected: (@Sendable (MuxError) -> Void)?)
    case paste(String, completion: (Result<PasteState, MuxError>) -> Void)
  }

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

  /// Ends the connection with `error` and cancels the channel, so the
  /// service releases any lease it holds.
  private func fail(_ error: MuxError) {
    cancelChannel()
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
    let queued = pasting.values.flatMap { $0 }
    pasting = [:]
    pasteRefusals = [:]
    for job in queued {
      switch job {
      case let .input(_, rejected): rejected?(error)
      case let .paste(_, completion): completion(.failure(error))
      }
    }
  }

  private func cancelChannel() {
    guard !channelCancelled else { return }
    channelCancelled = true
    channel.cancel()
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
    let queue = queue
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { waiter = $0 }
    } onCancel: {
      // Stops waiting; a later event stays buffered for the next call.
      queue.async { [weak self] in
        self?
          .assumeIsolated { connection in
            guard let waiter = connection.waiter else { return }
            connection.waiter = nil
            waiter.resume(throwing: CancellationError())
          }
      }
    }
  }

  /// Executes a command. Acknowledgement means the operation committed.
  /// Cancelling the calling task, or `timeout` passing, stops waiting
  /// (a late reply is dropped); the command may still commit.
  @discardableResult
  public func execute(
    _ command: MuxCommand,
    timeout: Duration? = nil
  ) async throws -> MuxReply {
    if let closedError { throw closedError }
    let id = nextRequest
    nextRequest += 1
    if let timeout {
      queue.asyncAfter(deadline: .now() + timeout.timeInterval) {
        [weak self] in
        self?
          .assumeIsolated {
            $0.abandon(id, MuxError(.connectionLost, "no reply in time"))
          }
      }
    }
    let queue = queue
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        requests[id] = continuation
        if let error = request(id, command) {
          abandon(id, error)
        }
      }
    } onCancel: {
      // Runs after the continuation is registered: the actor's executor
      // is this queue.
      queue.async { [weak self] in
        self?.assumeIsolated { $0.abandon(id, CancellationError()) }
      }
    }
  }

  /// Resumes a pending request with `error`, at most once.
  private func abandon(_ id: UInt64, _ error: any Error) {
    requests.removeValue(forKey: id)?.resume(throwing: error)
  }

  /// Sends one request. A request too large to encode is refused alone;
  /// the connection stays up.
  private func request(_ id: UInt64, _ command: MuxCommand) -> MuxError? {
    do {
      channel.send(try encode(.request(id: id, command: command)))
      return nil
    } catch { return error }
  }

  /// Sends semantic input; returns once admitted to the pane's writer.
  public func send(_ input: MuxInput, to pane: PaneID) async throws {
    try await submit(pane, .input(input))
  }

  /// Sends input without waiting for admission. Errors are dropped; the
  /// caller keeps order because records are sent in call order.
  public func post(_ input: MuxInput, to pane: PaneID) {
    guard attachment != nil, closedError == nil else { return }
    if let queued = pasting[pane], !queued.isEmpty {
      pasting[pane]?.append(.input(input, rejected: nil))
      return
    }
    transmitInput(input, to: pane, rejected: nil)
  }

  /// Sends input records; text longer than a paste chunk is split on
  /// scalar boundaries so each record stays within the record limit.
  private func transmitInput(
    _ input: MuxInput,
    to pane: PaneID,
    rejected: (@Sendable (MuxError) -> Void)?
  ) {
    guard let attachment, closedError == nil else {
      rejected?(closedError ?? MuxError(.notAttached))
      return
    }
    let parts: [MuxInput]
    let maxBytes = (welcome?.limits ?? .standard).maxPasteChunkBytes
    if case let .text(text) = input, text.utf8.count > maxBytes {
      parts = Self.chunks(text, maxBytes: maxBytes).map { .text($0) }
    } else {
      parts = [input]
    }
    for part in parts {
      let sequence = nextInput
      nextInput += 1
      if let rejected {
        inputs[sequence] = { if let e = $0 { rejected(e) } }
      }
      transmit(
        .input(
          InputRecord(
            sequence: sequence,
            attachment: attachment,
            pane: pane,
            payload: .input(part)
          )
        )
      )
    }
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
        if connection.closedError == nil,
          let queued = connection.pasting[pane], !queued.isEmpty
        {
          // After a paste still waiting for its turn.
          connection.pasting[pane]?.append(.input(input, rejected: rejected))
          return
        }
        connection.transmitInput(input, to: pane, rejected: rejected)
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
        if let error = connection.request(id, command) {
          connection.callbacks.removeValue(forKey: id)?(.failure(error))
        }
      }
    }
  }

  /// Starts a paste in call order: its begin record precedes any later
  /// enqueued input, which the service defers until the envelope closes.
  /// A paste to a pane with one still open waits for it to close (and
  /// input enqueued after the waiting paste waits too).
  public nonisolated func enqueuePaste(
    _ text: String,
    to pane: PaneID,
    completion: (@Sendable (Result<PasteState, MuxError>) -> Void)? = nil
  ) {
    queue.async {
      self.assumeIsolated { connection in
        connection.schedulePaste(text, to: pane) { completion?($0) }
      }
    }
  }

  private func schedulePaste(
    _ text: String,
    to pane: PaneID,
    completion: @escaping (Result<PasteState, MuxError>) -> Void
  ) {
    let limits = welcome?.limits ?? .standard
    guard attachment != nil, closedError == nil else {
      completion(.failure(closedError ?? MuxError(.notAttached)))
      return
    }
    guard text.utf8.count <= limits.maxPasteBytes else {
      completion(
        .failure(
          MuxError(.resourceLimit, "paste exceeds \(limits.maxPasteBytes) bytes")
        )
      )
      return
    }
    if pasting[pane] != nil {
      pasting[pane]?.append(.paste(text, completion: completion))
      return
    }
    beginPaste(text, to: pane, completion: completion)
  }

  /// Sends the begin record and the body; the pane's next queued paste
  /// starts once this one's envelope is closed.
  private func beginPaste(
    _ text: String,
    to pane: PaneID,
    completion: @escaping (Result<PasteState, MuxError>) -> Void
  ) {
    guard let attachment, closedError == nil else {
      completion(.failure(closedError ?? MuxError(.notAttached)))
      return
    }
    pasting[pane] = []
    let id = nextPaste
    nextPaste += 1
    let sequence = nextInput
    nextInput += 1
    inputs[sequence] = { [weak self] error in
      if let error { self?.assumeIsolated { $0.pasteRefusals[id] = error } }
    }
    transmit(
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
      let result = await self.pasteBody(id: id, text: text, pane: pane)
      self.pasteFinished(pane)
      completion(result)
    }
  }

  /// Sends what waited behind the pane's paste, up to its next paste.
  private func pasteFinished(_ pane: PaneID) {
    var queued = pasting.removeValue(forKey: pane) ?? []
    while !queued.isEmpty {
      switch queued.removeFirst() {
      case let .input(input, rejected):
        transmitInput(input, to: pane, rejected: rejected)
      case let .paste(text, completion):
        beginPaste(text, to: pane, completion: completion)
        if pasting[pane] != nil { pasting[pane] = queued }
        return
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
          if let refused = pasteRefusals.removeValue(forKey: id) {
            // The service never opened this envelope.
            return .failure(refused)
          }
          // Close the envelope on the service: an open paste would keep
          // deferring this pane's later input and refuse a new paste.
          try? await submit(pane, .pasteCancel(id: id))
          return .success(sent > 0 ? .partial : .aborted)
        }
      }
      sent += chunk.utf8.count
    }
    do { try await submit(pane, .pasteEnd(id: id)) } catch {
      return .failure(
        pasteRefusals.removeValue(forKey: id) ?? error as? MuxError
          ?? MuxError(.connectionLost)
      )
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
    if let closedError { throw closedError }
    guard attachment != nil else { throw MuxError(.notAttached) }
    return try await withCheckedThrowingContinuation { continuation in
      schedulePaste(text, to: pane) { continuation.resume(with: $0) }
    }
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

  /// Releases the attachment, bounded in time; panes keep running. A
  /// service that does not answer in time gets the connection closed,
  /// which releases the lease too.
  public func detach() async {
    guard attachment != nil, closedError == nil else { return }
    do { try await execute(.detach, timeout: detachTimeout) } catch {
      close()
    }
    attachment = nil
  }

  /// How long `detach` waits for the service.
  private var detachTimeout: Duration = .seconds(2)

  /// Shortens the detach bound (tests).
  package func setDetachTimeout(_ timeout: Duration) {
    detachTimeout = timeout
  }

  /// Closes the connection. An attached lease is released by the service.
  /// Also cancels the channel of a connection that already failed.
  public func close() {
    cancelChannel()
    guard !isClosed else { return }
    isClosed = true
    closedDeliberately = true
    let error = MuxError(.connectionLost, "closed")
    failPending(error)
    if let waiter {
      self.waiter = nil
      waiter.resume(returning: nil)
    }
  }

  /// Sends one record. One that cannot be encoded would leave a gap in
  /// the input sequence, so it fails the connection (cancelling the
  /// channel, which releases its lease).
  private func transmit(_ message: ClientMessage) {
    do { channel.send(try encode(message)) } catch { fail(error) }
  }

  private func encode(_ message: ClientMessage) throws(MuxError) -> Data {
    try SMXCodec.encode(
      message,
      limit: SMXCodec.clientRecordLimit(welcome?.limits ?? .standard)
    )
  }
}
