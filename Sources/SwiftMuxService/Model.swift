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

final class Client {
  let id = UUID()
  let channel: SMXChannel
  var hello: Hello?

  init(channel: SMXChannel) { self.channel = channel }
}

struct FrameSlot {
  var dirty = true
  var capturing = false
  var inflight: (revision: UInt64, bytes: Int)?
  var lastSent: UInt64 = 0
}

struct ActivePaste {
  var pane: PaneID
  var bytes = 0
}

struct Lease {
  let client: UUID
  let attachment = AttachmentID()
  var workspace: WorkspaceID
  var subscriptions: [PaneID] = []
  var frames: [PaneID: FrameSlot] = [:]
  var geometryGeneration: UInt64 = 0
  var pastes: [UInt64: ActivePaste] = [:]
}
