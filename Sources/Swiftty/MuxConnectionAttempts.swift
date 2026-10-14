import Foundation
import SwiftMuxClient
import SwiftMuxProtocol
import Synchronization

/// Owns only connection creation, so retiring an old window during a
/// successful replacement cannot cancel the replacement itself.
@MainActor
final class MuxConnectionAttempts {
  static let maxPending = MuxConnection.maxPendingCommands
  private struct Attempt {
    let worker: Task<Void, Never>
    let wait: ConnectionWait
  }

  private var workers: [UUID: Attempt] = [:]
  var pendingCountForTesting: Int { workers.count }

  func connect(
    _ create: @escaping @MainActor () async throws -> MuxConnection
  ) async throws -> MuxConnection {
    try Task.checkCancellation()
    let id = UUID()
    let wait = ConnectionWait()
    return try await withTaskCancellationHandler {
      do {
        let connection = try await withCheckedThrowingContinuation { done in
          guard wait.install(done) else { return }
          guard workers.count < Self.maxPending else {
            _ = wait.complete(
              .failure(
                MuxError(
                  .resourceLimit,
                  "too many pending workspace connections",
                )
              )
            )
            return
          }
          let worker = Task {
            defer { workers.removeValue(forKey: id) }
            let result: Result<MuxConnection, any Error>
            do {
              try Task.checkCancellation()
              if wait.isCancelled { throw CancellationError() }
              result = try await .success(create())
            } catch { result = .failure(error) }
            if !wait.complete(result), case let .success(connection) = result {
              await connection.close()
            }
          }
          workers[id] = Attempt(worker: worker, wait: wait)
        }
        if Task.isCancelled {
          await connection.close()
          throw CancellationError()
        }
        return connection
      } catch {
        if Task.isCancelled { throw CancellationError() }
        throw error
      }
    } onCancel: { [weak self] in
      wait.cancel()
      Task { @MainActor in self?.workers[id]?.worker.cancel() }
    }
  }

  func cancel() {
    for attempt in workers.values {
      attempt.wait.cancel()
      attempt.worker.cancel()
    }
  }
}

/// Caller retirement is independent of a connector's cooperation. The
/// worker keeps its admission slot and disposes a result rejected here.
private final class ConnectionWait: Sendable {
  private struct State {
    var cancelled = false
    var finished = false
    var done: CheckedContinuation<MuxConnection, any Error>?
  }

  private let state = Mutex(State())
  var isCancelled: Bool { state.withLock { $0.cancelled } }

  func install(_ done: CheckedContinuation<MuxConnection, any Error>) -> Bool {
    let accepted = state.withLock { s in
      guard !s.cancelled else { return false }
      s.done = done
      return true
    }
    if !accepted { done.resume(throwing: CancellationError()) }
    return accepted
  }

  func complete(_ result: Result<MuxConnection, any Error>) -> Bool {
    let done = state.withLock { s in
      guard !s.cancelled, !s.finished else {
        return nil as CheckedContinuation<MuxConnection, any Error, >?
      }
      s.finished = true
      return s.done.take()
    }
    guard let done else { return false }
    done.resume(with: result)
    return true
  }

  func cancel() {
    let done = state.withLock { s in
      guard !s.finished else {
        return nil as CheckedContinuation<MuxConnection, any Error, >?
      }
      s.cancelled = true
      return s.done.take()
    }
    done?.resume(throwing: CancellationError())
  }
}
