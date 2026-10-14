import SwiftMuxClient
import SwiftMuxProtocol
import Testing

@Suite
struct LayoutSequencerTests {
  let tab = TabID()

  func snapshot(
    _ id: WorkspaceID,
    _ revision: UInt64,
    name: String = ""
  ) -> WorkspaceSnapshot {
    WorkspaceSnapshot(
      id: id,
      name: name,
      tabs: [],
      activeTab: tab,
      panes: [],
      layoutRevision: revision
    )
  }

  @Test
  func attachShowsAndResyncs() {
    var s = LayoutSequencer()
    let one = WorkspaceID()
    #expect(s.attachedWorkspace == nil)
    #expect(
      s.attached(snapshot(one, 3)) == .show(snapshot(one, 3), resync: true)
    )
    #expect(s.attachedWorkspace == one)
  }

  @Test
  func layoutRevisionsOnlyMoveForward() {
    var s = LayoutSequencer()
    let one = WorkspaceID()
    _ = s.attached(snapshot(one, 3))
    #expect(s.layout(snapshot(one, 2)) == nil)
    #expect(
      s.layout(snapshot(one, 3)) == .show(snapshot(one, 3), resync: false)
    )
    #expect(
      s.layout(snapshot(one, 5)) == .show(snapshot(one, 5), resync: false)
    )
    #expect(s.layout(snapshot(one, 4)) == nil)
  }

  @Test
  func otherWorkspacesAreNotShown() {
    var s = LayoutSequencer()
    let one = WorkspaceID()
    _ = s.attached(snapshot(one, 1))
    #expect(s.layout(snapshot(WorkspaceID(), 9)) == nil)
    #expect(s.attachedWorkspace == one)
  }

  @Test
  func anEarlySnapshotOfTheSwitchTargetWinsWhenNewer() {
    var s = LayoutSequencer()
    let one = WorkspaceID()
    let two = WorkspaceID()
    _ = s.attached(snapshot(one, 1))
    // The target's layout event overtakes the switch reply.
    #expect(s.layout(snapshot(two, 6, name: "newer")) == nil)
    #expect(s.layout(snapshot(two, 5, name: "older")) == nil)
    #expect(
      s.attached(snapshot(two, 4))
        == .show(snapshot(two, 6, name: "newer"), resync: true)
    )
    // A late layout of the previous workspace is ignored.
    #expect(s.layout(snapshot(one, 50)) == nil)
    #expect(s.layout(snapshot(two, 5)) == nil)
  }

  @Test
  func anOlderEarlySnapshotLosesToTheReply() {
    var s = LayoutSequencer()
    let two = WorkspaceID()
    _ = s.attached(snapshot(WorkspaceID(), 1))
    _ = s.layout(snapshot(two, 2, name: "early"))
    #expect(
      s.attached(snapshot(two, 3)) == .show(snapshot(two, 3), resync: true)
    )
  }

  /// The service drops subscriptions on every switch, including to the
  /// workspace already attached.
  @Test
  func aSwitchToTheCurrentWorkspaceStillResyncs() {
    var s = LayoutSequencer()
    let one = WorkspaceID()
    _ = s.attached(snapshot(one, 3))
    #expect(
      s.attached(snapshot(one, 3)) == .show(snapshot(one, 3), resync: true)
    )
    // A newer layout already shown: keep it, but resync.
    _ = s.layout(snapshot(one, 7))
    #expect(s.attached(snapshot(one, 6)) == .resync)
    #expect(s.attachedWorkspace == one)
  }

  @Test
  func revisionHistoryKeepsOnlyTheShownWorkspace() {
    var s = LayoutSequencer()
    let one = WorkspaceID()
    let two = WorkspaceID()
    _ = s.attached(snapshot(one, 8))
    _ = s.layout(snapshot(one, 10))
    _ = s.attached(snapshot(two, 1))
    #expect(s.rememberedWorkspaceCount == 1)
    // The switch target's early layout still wins over an older reply.
    #expect(s.layout(snapshot(one, 12, name: "early")) == nil)
    #expect(
      s.attached(snapshot(one, 4))
        == .show(snapshot(one, 12, name: "early"), resync: true)
    )
    #expect(s.layout(snapshot(one, 11)) == nil)
    #expect(
      s.layout(snapshot(one, 13)) == .show(snapshot(one, 13), resync: false)
    )
    #expect(s.rememberedWorkspaceCount == 1)
  }

  @Test
  func returningToAWorkspaceShowsItsReply() {
    var s = LayoutSequencer()
    let one = WorkspaceID()
    let two = WorkspaceID()
    _ = s.attached(snapshot(one, 3))
    _ = s.attached(snapshot(two, 1))
    #expect(
      s.attached(snapshot(one, 4)) == .show(snapshot(one, 4), resync: true)
    )
  }
}
