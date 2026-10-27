import AppKit
import SwiftMuxProtocol
import SwifttyMac

/// Drops for programs registered through the kitty drag-and-drop protocol
/// (OSC 72), carried to the service as `MuxInput.drag`. Without a
/// registration the pane takes no drops.
extension MuxPaneView {
  func dropTargetChanged(_ types: [String]?) {
    dropTypes = types
    guard types != nil else {
      unregisterDraggedTypes()
      return
    }
    registerForDraggedTypes([.string, .fileURL, .URL])
  }

  override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation
  { dragMoved(sender) }

  override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation
  { dragMoved(sender) }

  override func draggingExited(_ sender: (any NSDraggingInfo)?) {
    guard dropTypes != nil else { return }
    controller?.send(.drag(.leave), to: pane)
  }

  override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
    guard dropTypes != nil else { return false }
    let pasteboard = sender.draggingPasteboard
    // The record carries the data: keep what fits one control record.
    var budget = MuxLimits.standard.maxControlRecordBytes / 2
    var items: [MuxClipboardContent] = []
    for mime in TerminalView.dragMimeTypes(on: pasteboard).prefix(16) {
      guard let item = TerminalView.dragContent(mime, on: pasteboard),
        item.data.count <= budget
      else { continue }
      budget -= item.data.count
      items.append(MuxClipboardContent(mime: item.mime, data: Data(item.data)))
    }
    controller?.send(.drag(.drop(position(sender), items: items)), to: pane)
    return true
  }

  private func dragMoved(_ sender: any NSDraggingInfo) -> NSDragOperation {
    guard dropTypes != nil else { return [] }
    controller?
      .send(
        .drag(
          .move(
            position(sender),
            types: Array(
              TerminalView.dragMimeTypes(on: sender.draggingPasteboard)
                .prefix(16)
            )
          )
        ),
        to: pane
      )
    // Until the program answers, offer a copy.
    switch (presented?.frame.dropTarget?.accepted) {
    case .none?: return []
    case .move?: return .move
    case .copy?, nil: return .copy
    }
  }

  private func position(_ sender: any NSDraggingInfo) -> MuxDragPosition {
    let p = convert(sender.draggingLocation, from: nil)
    let c = cell(at: p)
    let scale = window?.backingScaleFactor ?? 2
    let mask = sender.draggingSourceOperationMask
    return MuxDragPosition(
      column: max(0, c.column),
      row: max(0, c.row),
      pixelX: Int((p.x * scale - renderer.options.paddingX).rounded()),
      pixelY: Int(
        ((bounds.height - p.y) * scale - renderer.options.paddingY).rounded()
      ),
      allowsCopy: mask.contains(.copy),
      allowsMove: mask.contains(.move)
    )
  }
}
