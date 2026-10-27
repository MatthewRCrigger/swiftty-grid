#if os(macOS)
@testable import AppleTransport
import ScreenProtocol
import Synchronization
import Testing

@Suite(.serialized)
struct EventMailboxTests {
  private final class Probe: Sendable {
    let onDeinit: @Sendable () -> Void
    init(_ onDeinit: @escaping @Sendable () -> Void) {
      self.onDeinit = onDeinit
    }
    deinit { onDeinit() }
  }

  private struct WeakMailbox: Sendable { weak var value: EventMailbox? }

  private func eventually(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(1)
    while !condition() {
      try #require(ContinuousClock.now < deadline)
      try await Task.sleep(for: .milliseconds(1))
    }
  }

  @Test
  func callbackCapturesReleaseAfterClosureAndCannotRestart() async throws {
    let mailbox = EventMailbox()
    let entered = Mutex(false)
    let release = Mutex(false)
    let closed = Mutex(false)
    let retired = Mutex(false)
    defer { release.withLock { $0 = true } }
    func install() {
      let probe = Probe {
        // Deinitialization must be outside the mailbox lock.
        mailbox.post(.control([], done: {}))
        retired.withLock { $0 = true }
      }
      #expect(
        mailbox.start(
          RSTConnectionHandler(
            onControl: { _ in
              entered.withLock { $0 = true }
              while !release.withLock({ $0 }) {
                try? await Task.sleep(for: .milliseconds(1))
              }
              withExtendedLifetime(probe) {}
            },
            onClosed: { _ in closed.withLock { $0 = true } }
          )
        )
      )
    }
    install()
    mailbox.post(.control([1], done: {}))
    mailbox.post(.closed(nil))
    try await eventually { entered.withLock { $0 } }
    #expect(!retired.withLock { $0 } && !closed.withLock { $0 })
    release.withLock { $0 = true }
    try await eventually { closed.withLock { $0 } && retired.withLock { $0 } }
    #expect(!mailbox.hasHandler)
    let rejected = Mutex(false)
    func restart() {
      let probe = Probe { rejected.withLock { $0 = true } }
      #expect(
        !mailbox.start(
          RSTConnectionHandler(
            onControl: { _ in withExtendedLifetime(probe) {} },
            onClosed: { _ in }
          )
        )
      )
    }
    restart()
    #expect(rejected.withLock { $0 })
    let completed = Mutex(0)
    mailbox.post(.snapshot([2], done: { completed.withLock { $0 += 1 } }))
    #expect(completed.withLock { $0 } == 1)
  }

  @Test
  func handlersCapturingTheMailboxDoNotKeepItAliveAfterClosure() async throws {
    let weakMailbox = Mutex(WeakMailbox())
    let closed = Mutex(false)
    func installAndClose() {
      let mailbox = EventMailbox()
      weakMailbox.withLock { $0.value = mailbox }
      #expect(
        mailbox.start(
          RSTConnectionHandler(
            onControl: { _ in _ = mailbox.hasHandler },
            onClosed: { _ in closed.withLock { $0 = true } }
          )
        )
      )
      mailbox.post(.closed(nil))
    }
    installAndClose()
    try await eventually { closed.withLock { $0 } }
    try await eventually { weakMailbox.withLock { $0.value == nil } }
  }
}
#endif
