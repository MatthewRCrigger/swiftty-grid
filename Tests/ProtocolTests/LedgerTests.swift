import ScreenProtocol
import SessionCore
import Testing

struct LedgerTests {
  let writer = WriterID.random()

  @Test
  func `reserved operations count against the byte limit`() throws {
    var ledger = HostInputLedger(byteLimit: 256)
    try ledger.authorize(writer)
    var sequence: UInt64 = 0
    // Keys reserve 64 bytes each: four fit, the fifth is backpressure.
    while case .admit = ledger.classify(
      writer: writer,
      sequence: sequence + 1,
      operation: .key(SemanticKey(.enter))
    ) {
      sequence += 1
      ledger.reserve(sequence, operation: .key(SemanticKey(.enter)))
      #expect(sequence <= 4)
    }
    #expect(sequence == 4)
    #expect(ledger.pendingBytes == 256)
    // Completing the head releases its reservation.
    #expect(ledger.completeHead() == 1)
    #expect(ledger.pendingBytes == 192)
  }

  @Test
  func `an empty ledger admits a maximal paste`() throws {
    var ledger = HostInputLedger()
    try ledger.authorize(writer)
    let paste = InputOperation.paste(
      String(repeating: "x", count: RSTLimits.maxPasteBytes)
    )
    #expect(paste.expansionBound > ledger.byteLimit)
    #expect(
      ledger.classify(writer: writer, sequence: 1, operation: paste) == .admit
    )
    ledger.reserve(1, operation: paste)
    // A second operation waits for it.
    #expect(
      ledger.classify(writer: writer, sequence: 2, operation: paste)
        == .rejected(.backpressure)
    )
  }

  @Test
  func `zero byte operations are bounded behind a blocked write`() throws {
    var ledger = HostInputLedger(byteLimit: 100)
    try ledger.authorize(writer)
    let text = InputOperation.committedText("x")
    ledger.record(1, operation: text, bytes: [0x78])
    for sequence in UInt64(2) ... 4 {
      let resize = InputOperation.resize(
        columns: 80,
        rows: 24,
        resizeRevision: sequence
      )
      #expect(
        ledger.classify(writer: writer, sequence: sequence, operation: resize)
          == .admit
      )
      ledger.reserve(sequence, operation: resize)
    }
    let resize = InputOperation.resize(columns: 80, rows: 24, resizeRevision: 5)
    #expect(
      ledger.classify(writer: writer, sequence: 5, operation: resize)
        == .rejected(.backpressure)
    )
    #expect(ledger.wrote(1) == 1)
    #expect(
      ledger.classify(writer: writer, sequence: 5, operation: resize) == .admit
    )
  }

  @Test
  func `unsent operations are abandoned for a new writer`() throws {
    var ledger = HostInputLedger()
    try ledger.authorize(writer)
    ledger.reserve(1, operation: .committedText("x"))
    #expect(throws: HostInputLedger.Rejection.wrongWriter) {
      try ledger.authorize(WriterID.random())
    }
    ledger.abandonUnsent()
    try ledger.authorize(WriterID.random())
    #expect(ledger.lastApplied == 0)
  }

  @Test
  func `discarded operations are retired, never retried, and free the writer`()
    throws
  {
    var ledger = HostInputLedger()
    try ledger.authorize(writer)
    for n in 1 ... 3 {
      let op = InputOperation.committedText("x\(n)")
      #expect(
        ledger.classify(writer: writer, sequence: UInt64(n), operation: op)
          == .admit
      )
      ledger.record(UInt64(n), operation: op, bytes: [])
    }
    // A different writer cannot take over while operations are admitted.
    #expect(throws: HostInputLedger.Rejection.wrongWriter) {
      try ledger.authorize(WriterID.random())
    }
    #expect(ledger.discard(through: 1) == [1])
    #expect(ledger.discard(through: ledger.lastAdmitted) == [2, 3])
    #expect(!ledger.hasPending)
    // A retired operation is not admitted again.
    #expect(
      ledger.classify(
        writer: writer,
        sequence: 2,
        operation: .committedText("x2")
      ) == .alreadyApplied
    )
    try ledger.authorize(WriterID.random())
  }

  @Test
  func `host admits only the next sequence and deduplicates retries`() throws {
    var ledger = HostInputLedger()
    try ledger.authorize(writer)
    let a = InputOperation.committedText("ab")
    #expect(
      ledger.classify(writer: writer, sequence: 2, operation: a)
        == .rejected(.gap)
    )
    #expect(
      ledger.classify(writer: writer, sequence: 1, operation: a) == .admit
    )
    ledger.record(1, operation: a, bytes: Array("ab".utf8))
    // Identical retry continues; conflicting retry is rejected.
    #expect(
      ledger.classify(writer: writer, sequence: 1, operation: a) == .inProgress
    )
    #expect(
      ledger.classify(
        writer: writer,
        sequence: 1,
        operation: .committedText("x")
      ) == .rejected(.conflict)
    )
    // A partial write keeps the unwritten suffix only.
    #expect(ledger.wrote(1) == nil)
    #expect(ledger.partialSequence == 1)
    #expect(ledger.nextWrite.map { Array($0.bytes) } == Array("b".utf8))
    #expect(ledger.wrote(1) == 1)
    #expect(ledger.lastApplied == 1)
    #expect(
      ledger.classify(writer: writer, sequence: 1, operation: a)
        == .alreadyApplied
    )
    #expect(
      ledger.classify(writer: WriterID.random(), sequence: 2, operation: a)
        == .rejected(.wrongWriter)
    )
  }

  @Test
  func `resize completes only when performed`() throws {
    var ledger = HostInputLedger()
    try ledger.authorize(writer)
    let op = InputOperation.resize(columns: 90, rows: 30, resizeRevision: 1)
    #expect(
      ledger.classify(writer: writer, sequence: 1, operation: op) == .admit
    )
    ledger.record(1, operation: op, bytes: [])
    #expect(ledger.lastApplied == 0)
    #expect(ledger.completeHead() == 1)
    #expect(ledger.lastApplied == 1)
  }

  @Test
  func `writer takeover waits for admitted input and restarts sequence`() throws
  {
    var ledger = HostInputLedger()
    try ledger.authorize(writer)
    ledger.record(1, operation: .committedText("x"), bytes: [0x78])
    let next = WriterID.random()
    #expect(throws: HostInputLedger.Rejection.wrongWriter) {
      try ledger.authorize(next)
    }
    _ = ledger.wrote(1)
    try ledger.authorize(next)
    #expect(ledger.lastApplied == 0)
    #expect(
      ledger.classify(writer: next, sequence: 1, operation: .committedText("y"))
        == .admit
    )
  }

  @Test
  func `host bounds pending generated bytes`() throws {
    var ledger = HostInputLedger(byteLimit: 100)
    try ledger.authorize(writer)
    let small = InputOperation.paste(String(repeating: "x", count: 30))
    #expect(
      ledger.classify(writer: writer, sequence: 1, operation: small) == .admit
    )
    ledger.record(1, operation: small, bytes: Array(repeating: 0x78, count: 30))
    // 30 pending + a 60-byte paste's bound (132) exceeds the limit.
    let paste = InputOperation.paste(String(repeating: "x", count: 60))
    #expect(
      ledger.classify(writer: writer, sequence: 2, operation: paste)
        == .rejected(.backpressure)
    )
  }

  @Test
  func `client queue retains, acknowledges and reconciles`() throws {
    var queue = ClientInputQueue(writerID: writer, byteLimit: 200)
    let e1 = try queue.enqueue(.committedText("a"))
    let e2 = try queue.enqueue(.paste("b"))
    let e3 = try queue.enqueue(.key(SemanticKey(.enter)))
    #expect([e1, e2, e3].map(\.sequence) == [1, 2, 3])
    queue.acknowledge(through: 1)
    #expect(queue.entries.map(\.sequence) == [2, 3])
    // After reattachment the host reports progress; only the rest retries.
    #expect(queue.reconcile(serverApplied: 2).map(\.sequence) == [3])
    #expect(queue.acknowledged == 2)
    #expect(throws: ClientInputQueue.EnqueueError.full) {
      try queue.enqueue(.paste(String(repeating: "x", count: 300)))
    }
    #expect(throws: ClientInputQueue.EnqueueError.invalid(.pasteTooLarge)) {
      try queue.enqueue(.paste(String(repeating: "x", count: 40_000)))
    }
  }

  @Test
  func
    `exhaustive disconnect at every acknowledgment boundary applies each byte once`()
    throws
  {
    // A3: an oracle replays a stream of operations while the connection
    // drops after every possible number of written bytes.
    let ops: [InputOperation] = [
      .committedText("ls"), .key(SemanticKey(.enter)), .paste("échø"),
      .committedText("q"),
    ]
    let encoded: [[UInt8]] = ops.map {
      switch $0 {
      case let .committedText(t), let .paste(t): Array(t.utf8)
      default: [0x0D]
      }
    }
    let expected = encoded.flatMap(\.self)
    for cut in 0 ... expected.count {
      var host = HostInputLedger()
      try host.authorize(writer)
      var client = ClientInputQueue(writerID: writer)
      for op in ops { _ = try client.enqueue(op) }
      var pty: [UInt8] = []
      var budget = cut
      // Attempt 1: deliver until the cut, writing at most one byte at a time.
      for entry in client.entries {
        let admission = host.classify(
          writer: writer,
          sequence: entry.sequence,
          operation: entry.operation
        )
        if admission == .admit {
          host.record(
            entry.sequence,
            operation: entry.operation,
            bytes: encoded[Int(entry.sequence) - 1]
          )
        }
      }
      while budget > 0, let next = host.nextWrite {
        pty.append(next.bytes.first!)
        if let done = host.wrote(1) { client.acknowledge(through: done - 1) }
        budget -= 1
      }
      // Reattach: retry everything not acknowledged with original ids.
      for entry in client.reconcile(serverApplied: host.lastApplied) {
        let admission = host.classify(
          writer: writer,
          sequence: entry.sequence,
          operation: entry.operation
        )
        #expect(admission == .inProgress || admission == .admit)
        if admission == .admit {
          host.record(
            entry.sequence,
            operation: entry.operation,
            bytes: encoded[Int(entry.sequence) - 1]
          )
        }
      }
      while let next = host.nextWrite {
        pty += next.bytes
        _ = host.wrote(next.bytes.count)
      }
      #expect(pty == expected, "cut at \(cut)")
      #expect(host.lastApplied == UInt64(ops.count))
    }
  }

  @Test
  func `lifecycle allows only specified transitions`() throws {
    var life = ClientLifecycle()
    try life.transition(to: .sshBootstrap)
    try life.transition(to: .attaching)
    try life.transition(to: .active)
    #expect(life.state.acceptsInput)
    try life.transition(to: .suspect)
    try life.transition(to: .reconnecting)
    try life.transition(to: .attaching)
    try life.transition(to: .active)
    try life.transition(to: .backgroundDetached)
    #expect(!life.state.acceptsInput)
    #expect(throws: ClientLifecycle.TransitionError.self) {
      try life.transition(to: .active)
    }
    try life.transition(to: .sessionLost)
    #expect(throws: ClientLifecycle.TransitionError.self) {
      try life.transition(to: .attaching)
    }
  }

  @Test
  func `backoff follows the jittered schedule`() {
    var backoff = ReconnectBackoff()
    let delays = (0 ..< 8).map { _ in backoff.nextDelay() }
    for (delay, base) in zip(delays, [0.5, 1, 2, 4, 8, 15, 15, 15]) {
      #expect(delay >= base * 0.8 && delay <= min(base * 1.2, 15))
    }
    var liveness = LivenessPolicy()
    #expect(liveness.staleTimeout == .seconds(2))
    liveness.sample(.seconds(1))
    #expect(liveness.staleTimeout == .seconds(4))
    #expect(!liveness.isStale(awaitingResponseFor: nil))
    #expect(liveness.isStale(awaitingResponseFor: .seconds(5)))
  }

  @Test(arguments: [
    -1.0, Double.nan, Double.infinity, -Double.infinity, 2.0,
    Double.greatestFiniteMagnitude,
  ])
  func invalidJitterProducesFiniteNonnegativeDelays(jitter: Double) {
    var backoff = ReconnectBackoff(jitter: jitter)
    #expect(backoff.jitter.isFinite)
    #expect((0 ... 1).contains(backoff.jitter))
    for _ in 0 ..< 100 {
      let delay = backoff.nextDelay()
      #expect(delay.isFinite)
      #expect((0 ... 15).contains(delay))
    }
    if jitter < 0 || !jitter.isFinite {
      backoff.reset()
      #expect(backoff.nextDelay() == 0.5)
    }
  }
}
