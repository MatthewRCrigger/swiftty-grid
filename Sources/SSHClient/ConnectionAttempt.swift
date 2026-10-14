import Foundation
import NIOCore
import Synchronization

/// Owns setup futures and every Happy Eyeballs candidate until one connection
/// is handed to the caller. Cancellation does not wait for DNS to cooperate.
final class ConnectionAttempt: Sendable {
  private struct OwnedChannel: Sendable {
    let channel: any Channel
    let close: @Sendable (any Channel) -> Void
  }

  private struct State {
    var error: (any Error)?
    var finished = false
    var channels: [ObjectIdentifier: OwnedChannel] = [:]
    var waiters: [UUID: @Sendable (any Error) -> Void] = [:]
  }

  private let state = Mutex(State())
  let deadline: NIODeadline

  private let timeoutError: any Error

  init(
    deadline: NIODeadline,
    timeoutError: any Error = SSHClientError.connectTimeout,
  ) {
    self.deadline = deadline
    self.timeoutError = timeoutError
  }

  var failure: (any Error)? {
    state.withLock { state -> (any Error)? in
      if let error = state.error { return error }
      if !state.finished, NIODeadline.now() >= deadline { return timeoutError }
      return nil
    }
  }

  func register(
    _ channel: any Channel,
    close: @escaping @Sendable (any Channel) -> Void = {
      $0.close(promise: nil)
    },
  ) throws {
    if NIODeadline.now() >= deadline { abort(timeoutError) }
    let id = ObjectIdentifier(channel)
    let error = state.withLock { state -> (any Error)? in
      if let error = state.error { return error }
      guard !state.finished else { return SSHClientError.connectionClosed }
      state.channels[id] = OwnedChannel(channel: channel, close: close)
      return nil
    }
    if let error {
      close(channel)
      throw error
    }
    channel.closeFuture.whenComplete { _ in
      self.state.withLock { _ = $0.channels.removeValue(forKey: id) }
    }
  }

  func wait<Value: Sendable>(
    for future: EventLoopFuture<Value>,
    discard: @escaping @Sendable (Value) -> Void = { _ in },
  ) async throws -> Value {
    if NIODeadline.now() >= deadline { abort(timeoutError) }
    let id = UUID()
    let promise = future.eventLoop.makePromise(of: Value.self)
    let error = state.withLock { state -> (any Error)? in
      if let error = state.error { return error }
      guard !state.finished else { return SSHClientError.connectionClosed }
      state.waiters[id] = { promise.fail($0) }
      return nil
    }
    future.whenComplete { result in
      let waiting = self.state.withLock {
        $0.waiters.removeValue(forKey: id) != nil
      }
      if waiting {
        promise.completeWith(result)
      } else if case let .success(value) = result {
        discard(value)
      }
    }
    if let error { promise.fail(error) }
    return try await promise.futureResult.get()
  }

  func abort(_ error: any Error) {
    let owned = state.withLock {
      state -> (
        error: (any Error)?, channels: [OwnedChannel],
        waiters: [@Sendable (any Error) -> Void],
      ) in
      guard !state.finished else { return (nil, [], []) }
      if state.error == nil { state.error = error }
      let owned = (
        state.error, Array(state.channels.values), Array(state.waiters.values),
      )
      state.channels.removeAll()
      state.waiters.removeAll()
      return owned
    }
    guard let reason = owned.error else { return }
    for waiter in owned.waiters { waiter(reason) }
    for channel in owned.channels { channel.close(channel.channel) }
  }

  func finish(keeping winner: (any Channel)?) throws {
    let owned = state.withLock {
      state -> (error: (any Error)?, channels: [OwnedChannel], ) in
      if state.error == nil, NIODeadline.now() >= deadline {
        state.error = timeoutError
      }
      state.finished = true
      let winnerID = winner.map(ObjectIdentifier.init)
      let discarded = state.channels
        .filter { state.error != nil || $0.key != winnerID }.map(\.value)
      state.channels.removeAll()
      return (state.error, discarded)
    }
    for channel in owned.channels { channel.close(channel.channel) }
    if let error = owned.error { throw error }
  }
}
