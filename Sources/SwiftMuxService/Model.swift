import Foundation
import SwiftMuxProtocol

struct Tab {
  var id = TabID()
  var name: String
  var layout: LayoutNode
  var activePane: PaneID
  var zoomedPane: PaneID?

  var snapshot: TabSnapshot {
    TabSnapshot(
      id: id,
      name: name,
      layout: layout,
      activePane: activePane,
      zoomedPane: zoomedPane
    )
  }
}

struct Workspace {
  var id = WorkspaceID()
  var name: String
  var createdAt = Date()
  var tabs: [Tab]
  var activeTab: TabID
  var remainOnExit: Bool
  /// Environment snapshot taken at creation; new panes reuse it.
  var launch: LaunchSpec
  var layoutRevision: UInt64 = 1

  func tabIndex(containing pane: PaneID) -> Int? {
    tabs.firstIndex { $0.layout.contains(pane) }
  }

  var allPanes: [PaneID] { tabs.flatMap(\.layout.panes) }
}

struct PaneRecord {
  let runtime: PaneRuntime
  let workspace: WorkspaceID
  var columns: Int
  var rows: Int
  var title = ""
  var workingDirectory: String?
  var exitStatus: Int32?
  /// Removed from the layout; kept only until its process is reaped.
  var detachedFromLayout = false

  func summary(_ id: PaneID) -> PaneSummary {
    PaneSummary(
      id: id,
      columns: columns,
      rows: rows,
      title: title,
      pid: runtime.pid > 0 ? runtime.pid : nil,
      exitStatus: exitStatus,
      workingDirectory: workingDirectory
    )
  }
}

/// How the service reaches a client.
enum ClientTransport {
  case xpc(SMXChannel)
  /// In-process (the roaming bridge): values, never encoded.
  case local(LocalClientSink)
}

final class Client {
  let id: UUID
  let transport: ClientTransport
  var hello: Hello?
  /// Receives `workspaces` events (metadata only, no lease).
  var observesWorkspaces = false
  /// Receives `inbox` events.
  var subscribesInbox = false
  /// Bridged from the roaming transport rather than local XPC.
  var remote = false

  init(channel: SMXChannel) {
    id = UUID()
    transport = .xpc(channel)
  }

  init(id: UUID, local sink: LocalClientSink, remote: Bool) {
    self.id = id
    transport = .local(sink)
    self.remote = remote
  }

  var local: LocalClientSink? {
    if case let .local(sink) = transport { sink } else { nil }
  }

  func cancel() {
    switch transport {
    case let .xpc(channel): channel.cancel()
    case let .local(sink): sink.onClosed("closed by service")
    }
  }
}

struct FrameSlot {
  var dirty = true
  /// Token of the capture in progress; a completion carrying any other
  /// token belongs to an earlier subscription and is dropped.
  var capture: UInt64?
  /// Budget held for `capture` until it completes or the slot goes.
  var reserved = 0
  var inflight: (revision: UInt64, bytes: Int)?
  var lastSent: UInt64 = 0
}

struct ActivePaste {
  var pane: PaneID
  var bytes = 0
}

/// One interactive lease on one workspace (spec.inbox.md §2). A client
/// holds at most one; a workspace has at most one holder.
struct Lease {
  let client: UUID
  let attachment = AttachmentID()
  var workspace: WorkspaceID
  /// The workspace's lease generation when this lease was granted.
  var generation: UInt64
  var holder: LeaseHolder
  /// Next input sequence this attachment may submit (watermark + 1).
  var nextInput: UInt64 = 1
  var subscriptions: [PaneID] = []
  var frames: [PaneID: FrameSlot] = [:]
  /// Rotates which subscribed pane is captured first.
  var paneCursor = 0
  var geometryGeneration: UInt64 = 0
  var pastes: [UInt64: ActivePaste] = [:]
  /// Unsubscribed panes already reported through `activity`.
  var reportedActivity: Set<PaneID> = []
}
