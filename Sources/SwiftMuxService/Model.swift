import Foundation
import SwiftMuxProtocol

public struct MuxServiceConfiguration: Sendable {
  /// Private fixture observation; production callers leave this nil.
  var observePaneIO: (@Sendable (PaneID, PaneIOObservation) -> Void)?
  public var launcherPath: String
  public var limits = MuxLimits.standard
  public var innerTerm = SMX.fallbackInnerTerm
  public var terminfoDirectory: String?
  /// Code-signing requirement every peer must satisfy (shipping builds).
  public var peerRequirement: String?
  /// Exit delay once the service reaches its empty-state barrier; nil
  /// keeps the service running (tests, foreground use). Invalid delays
  /// also keep it running rather than triggering an immediate exit.
  public var idleExitDelay: TimeInterval?
  /// Runs on the pane queue before each launch (tests hold a launch open).
  package var beforeLaunch: (@Sendable () -> Void)?

  public init(launcherPath: String) { self.launcherPath = launcherPath }
}

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
  /// Local use survives detach; remote reservation expiry must not end
  /// a workspace that another frontend has already used.
  var wasAttachedLocally = false
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

struct QueuedFrame {
  var revision: UInt64
  var bytes: Int
  var geometry: UInt64
  var data: Data
}

struct FrameSlot {
  var dirty = true
  /// Output while the tab was hidden but its old subscription remained.
  var hiddenActivity = false
  /// Token of the capture in progress; a completion carrying any other
  /// token belongs to an earlier subscription and is dropped.
  var capture: UInt64?
  /// Budget held for `capture` until it completes or the slot goes.
  var reserved = 0
  var inflight: (revision: UInt64, bytes: Int)?
  var inflightGeometry: UInt64 = 0
  /// Newest complete frame waiting behind the one in flight. Replaced,
  /// never queued deeper than one.
  var queued: QueuedFrame?
  var lastSent: UInt64 = 0
  var lastCapture: UInt64 = 0
}

/// Initial-frame gate. Hidden panes are never required.
struct Readiness {
  var enabled = false
  var required: Set<PaneID> = []
  var installed: [PaneID: (frame: UInt64, geometry: UInt64)] = [:]
  var sent = false
}

/// One viewer's window. Display size never changes the PTY.
struct ViewerViewport: Sendable {
  var followTail: Bool
  var historyGeneration: UInt64
  var anchorRow: Int?
  var rows: Int?
  var columns: Int?
  var searchQuery: String?
  /// Match index from the last search reply. Capture reselects it after
  /// `search` clears the engine selection.
  var searchSelected: Int?
  var revision: UInt64 = 1
}

struct ViewerCapture: Sendable {
  var followTail: Bool
  var historyGeneration: UInt64
  var anchorRow: Int?
  var rows: Int?
  var columns: Int?
  var searchQuery: String?
  var searchSelected: Int?
  var viewportRevision: UInt64
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
  var readiness = Readiness()
}

/// Read-only attachment. It never holds the writer lease or a paste.
struct Viewer {
  let client: UUID
  let attachment = AttachmentID()
  var workspace: WorkspaceID
  var subscriptions: [PaneID] = []
  var frames: [PaneID: FrameSlot] = [:]
  var paneCursor = 0
  var reportedActivity: Set<PaneID> = []
  var viewports: [PaneID: ViewerViewport] = [:]
  var readiness = Readiness()
  var unavailable: Set<PaneID> = []
}
