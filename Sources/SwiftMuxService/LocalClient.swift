import Dispatch
import Foundation
import SwiftMuxProtocol
import SwifttyEngine

/// Callbacks for an in-process client, invoked on the service queue.
package final class LocalClientSink: Sendable {
  let onMessage: @Sendable (ServerMessage) -> Void
  /// A pane of the leased workspace changed; export when convenient.
  let onPaneChanged: @Sendable (PaneID) -> Void
  let onClosed: @Sendable (String) -> Void

  package init(
    onMessage: @escaping @Sendable (ServerMessage) -> Void,
    onPaneChanged: @escaping @Sendable (PaneID) -> Void,
    onClosed: @escaping @Sendable (String) -> Void
  ) {
    self.onMessage = onMessage
    self.onPaneChanged = onPaneChanged
    self.onClosed = onClosed
  }
}

/// An SMX client inside the service process: the roaming (RST/1) bridge
/// attaches through this, so remote attachments obey the same leases,
/// takeover fencing, input ledger and pane ownership as local XPC ones
/// (spec.inbox.md §1, §12 risk 7). Values are passed without encoding;
/// frames are not delivered (`setSubscriptions` must stay empty): the
/// client exports screens itself with `inspect`.
package final class MuxLocalConnection: Sendable {
  package let service: MuxService
  let id: UUID

  init(service: MuxService, id: UUID) {
    self.service = service
    self.id = id
  }

  /// Handled in order with every other client's messages.
  package func send(_ message: ClientMessage) {
    let id = id
    service.queue.async {
      self.service.assumeIsolated { $0.receive(message, from: id) }
    }
  }

  /// Like a dropped connection: the lease (if any) is released and
  /// remaining paste input is cancelled. Panes keep running.
  package func close() {
    let id = id
    service.queue.async {
      self.service.assumeIsolated {
        $0.disconnected(id, reason: "in-process client closed")
      }
    }
  }
}

extension MuxService {
  /// Connects an in-process client. `remote` marks its leases as held
  /// over the roaming transport.
  package nonisolated func connectLocal(
    remote: Bool,
    sink: LocalClientSink
  ) -> MuxLocalConnection {
    let id = UUID()
    queue.async {
      self.assumeIsolated {
        $0.register(Client(id: id, local: sink, remote: remote))
      }
    }
    return MuxLocalConnection(service: self, id: id)
  }

  /// Runs `body` in `pane`'s order with its authoritative terminal
  /// state; nil when the pane is gone.
  package nonisolated func inspect<T: Sendable>(
    pane: PaneID,
    _ body: @escaping @Sendable (borrowing TerminalState) -> T,
    completion: @escaping @Sendable (T?) -> Void
  ) {
    queue.async {
      self.assumeIsolated { service in
        guard let runtime = service.runtime(pane) else {
          return completion(nil)
        }
        runtime.inspect(body) { completion($0) }
      }
    }
  }
}
