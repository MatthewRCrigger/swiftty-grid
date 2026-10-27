import SwiftMuxClient
import SwiftMuxProtocol
import Synchronization

/// Reserves payload bytes and job slots until the ordered writer finishes.
@MainActor
final class MuxInputQueue {
  private let continuation: AsyncStream<InputEntry>.Continuation
  private let budget = InputBudget()
  private let limits: MuxLimits
  private let refused: @MainActor @Sendable (String) -> Void
  private var worker: Task<Void, Never>?

  init(
    connection: MuxConnection,
    limits: MuxLimits,
    refused: @escaping @MainActor @Sendable (String) -> Void,
  ) {
    self.limits = limits
    self.refused = refused
    let (stream, continuation) = AsyncStream<InputEntry>.makeStream()
    self.continuation = continuation
    worker = Task.detached {
      for await entry in stream {
        defer { entry.release() }
        guard !Task.isCancelled else { break }
        do {
          switch entry.job {
          case let .input(input, pane):
            try await connection.send(input, to: pane)
          case let .paste(text, pane):
            let result = try await connection.paste(text, to: pane)
            if !Task.isCancelled {
              switch result {
              case .completed: break
              case .partial: await refused("Paste was only partially sent.")
              case .aborted: await refused("Paste was not sent.")
              }
            }
          }
        } catch {
          guard !Task.isCancelled else { break }
          let detail = (error as? MuxError)?.message ?? ""
          await refused(detail.isEmpty ? "Input could not be sent." : detail)
        }
      }
    }
  }

  func send(_ input: MuxInput, to pane: PaneID) {
    switch input {
    case let .text(text):
      admit(
        .input(input, pane),
        bytes: text.utf8.count,
        limit: InputBudget.byteLimit,
      )
    case let .paste(text):
      admit(
        .input(input, pane),
        bytes: text.utf8.count,
        limit: limits.maxPasteChunkBytes,
      )
    case .key, .focus, .mouse, .moveCursor, .clipboardPaste, .drag(.move),
      .drag(.leave):
      admit(.input(input, pane), bytes: 32, limit: InputBudget.byteLimit, )
    case let .drag(.drop(_, items)):
      // The record carries the dropped data (base64 in JSON).
      admit(
        .input(input, pane),
        bytes: items.reduce(0) { $0 + $1.data.count } * 4 / 3,
        limit: limits.maxControlRecordBytes - 4096,
      )
    }
  }

  func paste(_ text: String, to pane: PaneID) {
    admit(
      .paste(text, pane),
      bytes: text.utf8.count,
      limit: limits.maxPasteBytes,
    )
  }

  private func admit(_ job: QueuedInput, bytes: Int, limit: Int) {
    guard worker != nil else { return }
    guard bytes <= limit else {
      refused("Input is too large and was not sent.")
      return
    }
    guard budget.reserve(bytes) else {
      refused("Input buffer is full. New input was not sent.")
      return
    }
    continuation.yield(InputEntry(job: job, bytes: bytes, budget: budget))
  }

  func stop() {
    continuation.finish()
    worker?.cancel()
    worker = nil
  }

  deinit {
    continuation.finish();
    worker?.cancel()
  }
}

private enum QueuedInput: Sendable {
  case input(MuxInput, PaneID)
  case paste(String, PaneID)
}

private final class InputBudget: Sendable {
  static let byteLimit = 4 << 20
  private let state = Mutex((jobs: 0, bytes: 0))

  func reserve(_ bytes: Int) -> Bool {
    state.withLock {
      guard $0.jobs < 256, bytes <= Self.byteLimit - $0.bytes else {
        return false
      }
      $0.jobs += 1
      $0.bytes += bytes
      return true
    }
  }

  func release(_ bytes: Int) {
    state.withLock {
      $0.jobs -= 1;
      $0.bytes -= bytes
    }
  }
}

private final class InputEntry: Sendable {
  let job: QueuedInput
  private let bytes: Int
  private let budget: InputBudget
  private let charged = Mutex(true)

  init(job: QueuedInput, bytes: Int, budget: InputBudget) {
    self.job = job
    self.bytes = bytes
    self.budget = budget
  }

  func release() {
    let release = charged.withLock { charged in
      guard charged else { return false }
      charged = false
      return true
    }
    if release { budget.release(bytes) }
  }

  deinit { release() }
}
