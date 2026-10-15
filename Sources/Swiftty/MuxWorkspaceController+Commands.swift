import AppKit
import SwiftMuxProtocol

/// Workspace menu commands. They travel the responder chain, so each
/// reaches the focused window's controller (the window's delegate), never
/// another workspace; a text field or field editor that handles a
/// selector itself keeps it.
extension MuxWorkspaceController {
  @objc
  func newTerminalTab(_ sender: Any?) { newTab() }

  @objc
  func splitRight(_ sender: Any?) { split(.leftRight) }

  @objc
  func splitDown(_ sender: Any?) { split(.topBottom) }

  @objc
  func toggleZoomPane(_ sender: Any?) { toggleZoom() }

  @objc
  func endActivePane(_ sender: Any?) { endPane() }

  @objc
  func endActiveTab(_ sender: Any?) { closeTab() }

  @objc
  func endCurrentWorkspace(_ sender: Any?) { endWorkspace() }

  @objc
  func renameActiveTab(_ sender: Any?) { beginRenamingActiveTab() }

  @objc
  func renameCurrentWorkspace(_ sender: Any?) { beginRenamingWorkspace() }

  @objc
  func selectNextTab(_ sender: Any?) { cycleTab(1) }

  @objc
  func selectPreviousTab(_ sender: Any?) { cycleTab(-1) }

  /// Focus and resize items carry their direction in the tag.
  @objc
  func focusPaneInDirection(_ sender: NSMenuItem) {
    Self.direction(sender.tag).map { focus($0) }
  }

  @objc
  func resizePaneInDirection(_ sender: NSMenuItem) {
    Self.direction(sender.tag).map { resizeActivePane($0) }
  }

  static let directions: [Direction] = [.left, .right, .up, .down]

  static func direction(_ tag: Int) -> Direction? {
    directions.indices.contains(tag) ? directions[tag] : nil
  }

  @objc
  func increaseFontSize(_ sender: Any?) { adjustFontSize(by: 1) }

  @objc
  func decreaseFontSize(_ sender: Any?) { adjustFontSize(by: -1) }

  @objc
  func resetFontSize(_ sender: Any?) { setFontSize(nil) }

  /// Commands need this window's lease (a detached window offers none)
  /// and the target they name.
  @objc
  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    switch item.action {
    case #selector(increaseFontSize(_:)), #selector(decreaseFontSize(_:)),
      #selector(resetFontSize(_:)):
      return !isClosed
    default: break
    }
    guard holdsLease, let ws = workspace, let tab = activeTab else {
      return false
    }
    switch item.action {
    case #selector(selectNextTab(_:)), #selector(selectPreviousTab(_:)):
      return ws.tabs.count > 1
    case #selector(focusPaneInDirection(_:)):
      return tab.zoomedPane == nil && tab.layout.panes.count > 1
    case #selector(resizePaneInDirection(_:)): return tab.layout.panes.count > 1
    case #selector(splitRight(_:)), #selector(splitDown(_:)),
      #selector(toggleZoomPane(_:)), #selector(endActivePane(_:)):
      return ws.pane(tab.activePane) != nil
    default: return true
    }
  }
}
