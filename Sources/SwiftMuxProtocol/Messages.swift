import Foundation

/// SMX/1: tagged Codable records carried as bounded XPC data payloads.
public enum SMX {
  public static let protocolVersion = 1
  /// Versions this build can talk to. Only exact matches for now.
  public static let compatibleVersions: ClosedRange<Int> = 1 ... 1
  public static let build = "swiftmux-0.2"
  /// The one supported outer host profile for the terminal frontend.
  public static let terminalProfile = "swiftty-xterm-256color/1"
  /// The `TERM` installed for programs inside panes.
  public static let innerTerm = "swmux-256color"
  public static let fallbackInnerTerm = "xterm-256color"
  public static let defaultMachService = "com.chr33s.swiftty.swiftmux"
  public static let agentPlistName = "com.chr33s.swiftty.swiftmux.plist"
}

// MARK: Errors

public struct MuxError: Error, Codable, Sendable, Equatable,
  CustomStringConvertible
{
  public enum Code: String, Codable, Sendable {
    case alreadyAttached, notAttached, staleAttachment, staleGeometry
    case staleLayout, paneExited, historyUnavailable, resourceLimit
    case incompatibleVersion, notFound, invalidRequest, unauthorized
    case launchFailed, quiescing, serverInstanceChanged, connectionLost
  }

  public var code: Code
  public var message: String

  public init(_ code: Code, _ message: String = "") {
    self.code = code
    self.message = message
  }

  public var description: String {
    message.isEmpty ? code.rawValue : "\(code.rawValue): \(message)"
  }
}

// MARK: Handshake

public enum FrontendKind: String, Codable, Sendable {
  /// `swmux` inside Swiftty.
  case terminal
  /// Native Swiftty pane views.
  case native
  /// Status, registration and one-shot commands; never holds a lease.
  case control
}

public struct Hello: Codable, Sendable {
  public var protocolVersion: Int
  public var build: String
  public var frontend: FrontendKind
  public var terminalProfile: String?

  public init(
    frontend: FrontendKind,
    terminalProfile: String? = nil,
    protocolVersion: Int = SMX.protocolVersion,
    build: String = SMX.build
  ) {
    self.protocolVersion = protocolVersion
    self.build = build
    self.frontend = frontend
    self.terminalProfile = terminalProfile
  }
}

public struct Welcome: Codable, Sendable {
  public var protocolVersion: Int
  public var build: String
  public var server: ServerInstanceID
  public var acceptedProfile: String?
  public var limits: MuxLimits
  public var innerTerm: String

  public init(
    protocolVersion: Int,
    build: String,
    server: ServerInstanceID,
    acceptedProfile: String?,
    limits: MuxLimits,
    innerTerm: String
  ) {
    self.protocolVersion = protocolVersion
    self.build = build
    self.server = server
    self.acceptedProfile = acceptedProfile
    self.limits = limits
    self.innerTerm = innerTerm
  }
}

// MARK: Workspace model snapshots

public struct PaneSummary: Codable, Sendable, Equatable {
  public var id: PaneID
  public var columns: Int
  public var rows: Int
  public var title: String
  public var pid: Int32?
  /// Set once the pane's process exited and output drained.
  public var exitStatus: Int32?
  public var workingDirectory: String?

  public init(
    id: PaneID,
    columns: Int,
    rows: Int,
    title: String = "",
    pid: Int32? = nil,
    exitStatus: Int32? = nil,
    workingDirectory: String? = nil
  ) {
    self.id = id
    self.columns = columns
    self.rows = rows
    self.title = title
    self.pid = pid
    self.exitStatus = exitStatus
    self.workingDirectory = workingDirectory
  }
}

public struct TabSnapshot: Codable, Sendable, Equatable {
  public var id: TabID
  public var name: String
  public var layout: LayoutNode
  public var activePane: PaneID
  /// Displayed alone while set; the split tree is retained.
  public var zoomedPane: PaneID?

  public init(
    id: TabID,
    name: String,
    layout: LayoutNode,
    activePane: PaneID,
    zoomedPane: PaneID? = nil
  ) {
    self.id = id
    self.name = name
    self.layout = layout
    self.activePane = activePane
    self.zoomedPane = zoomedPane
  }
}

public struct WorkspaceSnapshot: Codable, Sendable, Equatable {
  public var id: WorkspaceID
  public var name: String
  public var tabs: [TabSnapshot]
  public var activeTab: TabID
  public var panes: [PaneSummary]
  /// Increments on every committed layout mutation.
  public var layoutRevision: UInt64

  public var activeTabSnapshot: TabSnapshot? {
    tabs.first { $0.id == activeTab }
  }

  public func pane(_ id: PaneID) -> PaneSummary? { panes.first { $0.id == id } }

  public func tab(containing pane: PaneID) -> TabSnapshot? {
    tabs.first { $0.layout.contains(pane) }
  }

  public init(
    id: WorkspaceID,
    name: String,
    tabs: [TabSnapshot],
    activeTab: TabID,
    panes: [PaneSummary],
    layoutRevision: UInt64
  ) {
    self.id = id
    self.name = name
    self.tabs = tabs
    self.activeTab = activeTab
    self.panes = panes
    self.layoutRevision = layoutRevision
  }
}

public struct WorkspaceSummary: Codable, Sendable, Equatable {
  public var id: WorkspaceID
  public var name: String
  public var tabCount: Int
  public var paneCount: Int
  public var createdAt: Date
  public var isAttached: Bool

  public init(
    id: WorkspaceID,
    name: String,
    tabCount: Int,
    paneCount: Int,
    createdAt: Date,
    isAttached: Bool
  ) {
    self.id = id
    self.name = name
    self.tabCount = tabCount
    self.paneCount = paneCount
    self.createdAt = createdAt
    self.isAttached = isAttached
  }
}

public struct ServiceStatus: Codable, Sendable, Equatable {
  public var server: ServerInstanceID
  public var build: String
  public var pid: Int32
  public var startedAt: Date
  public var workspaces: Int
  public var panes: Int
  public var attached: Bool
  public var quiescing: Bool
  public var innerTerm: String

  public init(
    server: ServerInstanceID,
    build: String,
    pid: Int32,
    startedAt: Date,
    workspaces: Int,
    panes: Int,
    attached: Bool,
    quiescing: Bool,
    innerTerm: String
  ) {
    self.server = server
    self.build = build
    self.pid = pid
    self.startedAt = startedAt
    self.workspaces = workspaces
    self.panes = panes
    self.attached = attached
    self.quiescing = quiescing
    self.innerTerm = innerTerm
  }
}

// MARK: Commands

/// Selects a workspace by identity or display name.
public enum WorkspaceSelector: Codable, Sendable, Equatable {
  case id(WorkspaceID)
  case name(String)
  /// The most recently created workspace.
  case latest
}

public struct LaunchSpec: Codable, Sendable, Equatable {
  /// Program and arguments; nil starts the user's login shell.
  public var command: [String]?
  public var workingDirectory: String?
  /// Environment snapshot, taken by the creating frontend.
  public var environment: [String: String]

  public init(
    command: [String]? = nil,
    workingDirectory: String? = nil,
    environment: [String: String] = [:]
  ) {
    self.command = command
    self.workingDirectory = workingDirectory
    self.environment = environment
  }
}

public struct NewWorkspaceRequest: Codable, Sendable, Equatable {
  public var name: String?
  public var columns: Int
  public var rows: Int
  public var launch: LaunchSpec
  /// Keep a pane's final screen after its process exits.
  public var remainOnExit: Bool

  public init(
    name: String? = nil,
    columns: Int = 80,
    rows: Int = 24,
    launch: LaunchSpec = LaunchSpec(),
    remainOnExit: Bool = false
  ) {
    self.name = name
    self.columns = columns
    self.rows = rows
    self.launch = launch
    self.remainOnExit = remainOnExit
  }
}

/// Cell dimensions for visible panes, computed by the frontend after
/// subtracting its own decoration.
public struct GeometryBatch: Codable, Sendable, Equatable {
  public struct Entry: Codable, Sendable, Equatable {
    public var pane: PaneID
    public var columns: Int
    public var rows: Int
    public init(pane: PaneID, columns: Int, rows: Int) {
      self.pane = pane
      self.columns = columns
      self.rows = rows
    }
  }

  public var layoutRevision: UInt64
  /// Frontend-chosen, increasing; frames echo the accepted generation.
  public var generation: UInt64
  public var entries: [Entry]

  public init(layoutRevision: UInt64, generation: UInt64, entries: [Entry]) {
    self.layoutRevision = layoutRevision
    self.generation = generation
    self.entries = entries
  }
}

/// Stable history address: absolute row valid for one addressing
/// generation of one screen.
public struct HistoryAddress: Codable, Sendable, Equatable {
  public var generation: UInt64
  public var alternateScreen: Bool
  public var row: Int

  public init(generation: UInt64, alternateScreen: Bool, row: Int) {
    self.generation = generation
    self.alternateScreen = alternateScreen
    self.row = row
  }
}

public enum ScrollRequest: Codable, Sendable, Equatable {
  /// Positive scrolls toward older history.
  case lines(Int)
  case pages(Int)
  case bottom
  /// Show `address` as the top viewport row.
  case top(HistoryAddress)
}

public enum MuxCommand: Codable, Sendable, Equatable {
  // Control (no lease required).
  case status
  case listWorkspaces
  case newWorkspace(NewWorkspaceRequest)
  case endWorkspace(WorkspaceSelector)
  case renameWorkspace(WorkspaceSelector, name: String)
  /// Releases the current interactive lease, whoever holds it.
  case detachActive
  /// Quiesce, then end every workspace and report the empty barrier.
  case endAllWorkspaces
  /// Stops (or resumes) admitting new workspaces and panes, for updates.
  case quiesce(Bool)

  // Attachment.
  case attach(WorkspaceSelector)
  case detach
  case switchWorkspace(WorkspaceSelector)

  // Layout (lease required).
  case newTab(name: String?, launch: LaunchSpec?)
  case selectTab(TabID)
  case renameTab(TabID, name: String)
  case endTab(TabID)
  case split(pane: PaneID, axis: SplitAxis, launch: LaunchSpec?)
  case focusPane(PaneID)
  case toggleZoom(TabID)
  case setSplitRatio(tab: TabID, path: [Bool], ratio: Double)
  case endPane(PaneID)
  case setGeometry(GeometryBatch)
  /// Visible panes whose frames this attachment wants.
  case setSubscriptions([PaneID])

  // History (lease required): the active attachment's viewport.
  case scroll(pane: PaneID, ScrollRequest)
  case search(pane: PaneID, query: String)
  case searchStep(pane: PaneID, forward: Bool)
  case endSearch(pane: PaneID)

  /// Whether this command needs the interactive lease.
  public var requiresLease: Bool {
    switch self {
    case .status, .listWorkspaces, .newWorkspace, .endWorkspace,
      .renameWorkspace, .detachActive, .endAllWorkspaces, .quiesce, .attach:
      false
    default: true
    }
  }
}

public struct SearchResult: Codable, Sendable, Equatable {
  public var matchCount: Int
  public var selected: Int?

  public init(matchCount: Int, selected: Int?) {
    self.matchCount = matchCount
    self.selected = selected
  }
}

public enum MuxReply: Codable, Sendable, Equatable {
  case ok
  case status(ServiceStatus)
  case workspaces([WorkspaceSummary])
  case created(WorkspaceSnapshot)
  case attached(attachment: AttachmentID, workspace: WorkspaceSnapshot)
  case layout(WorkspaceSnapshot)
  case pane(PaneID)
  case search(SearchResult)
}

// MARK: Input

public struct MuxKeyModifiers: OptionSet, Codable, Sendable, Hashable {
  public var rawValue: UInt8
  public init(rawValue: UInt8) { self.rawValue = rawValue }
  public static let shift = MuxKeyModifiers(rawValue: 1 << 0)
  public static let alt = MuxKeyModifiers(rawValue: 1 << 1)
  public static let control = MuxKeyModifiers(rawValue: 1 << 2)
}

public enum MuxKey: Codable, Sendable, Hashable {
  case character(UInt32)
  case enter, tab, backspace, escape
  case up, down, left, right
  case home, end, pageUp, pageDown, insert, delete
  case function(Int)
}

/// Semantic input; the service encodes it using authoritative pane modes.
public enum MuxInput: Codable, Sendable, Hashable {
  case text(String)
  case key(MuxKey, MuxKeyModifiers)
  case focus(Bool)
}

public enum InputPayload: Codable, Sendable, Equatable {
  case input(MuxInput)
  /// Starts a paste fixed to this record's pane and attachment.
  case pasteBegin(id: UInt64)
  case pasteChunk(id: UInt64, text: String)
  case pasteEnd(id: UInt64)
}

public struct InputRecord: Codable, Sendable, Equatable {
  public var sequence: UInt64
  public var attachment: AttachmentID
  public var pane: PaneID
  public var payload: InputPayload

  public init(
    sequence: UInt64,
    attachment: AttachmentID,
    pane: PaneID,
    payload: InputPayload
  ) {
    self.sequence = sequence
    self.attachment = attachment
    self.pane = pane
    self.payload = payload
  }
}

// MARK: Envelopes

public enum ClientMessage: Codable, Sendable {
  case hello(Hello)
  case request(id: UInt64, command: MuxCommand)
  case input(InputRecord)
  /// Releases transport credit for the pane's in-flight frame.
  case frameAck(pane: PaneID, revision: UInt64)
}

public enum MuxEvent: Codable, Sendable {
  case frame(PaneFrame)
  case layout(WorkspaceSnapshot)
  case paneExited(PaneID, status: Int32)
  case title(PaneID, String)
  case bell(PaneID)
  /// The lease ended without this client asking (e.g. another client
  /// released it, or the workspace ended).
  case detached(reason: String)
  case paste(id: UInt64, state: PasteState)
  /// A frame could not be exported; the session is preserved.
  case frameUnavailable(PaneID, MuxError)
}

public enum PasteState: String, Codable, Sendable {
  case completed, aborted, partial
}

public enum ServerMessage: Codable, Sendable {
  case welcome(Welcome)
  case rejected(MuxError)
  case reply(id: UInt64, result: MuxResult)
  /// Admission to the ordered writer, not execution by the shell.
  case inputAck(sequence: UInt64, error: MuxError?)
  case event(MuxEvent)
}

public enum MuxResult: Codable, Sendable, Equatable {
  case success(MuxReply)
  case failure(MuxError)

  public func get() throws(MuxError) -> MuxReply {
    switch self {
    case let .success(r): return r
    case let .failure(e): throw e
    }
  }
}
