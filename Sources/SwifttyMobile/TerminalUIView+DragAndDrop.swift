#if canImport(UIKit) && !os(tvOS)
import SwifttyCore
import UIKit
import UniformTypeIdentifiers

/// Drops for programs registered through the kitty drag-and-drop
/// protocol (OSC 72). Without a registration the view takes no drops.
extension TerminalUIView: UIDropInteractionDelegate {
  func dragAndDropRegistrationChanged() {
    let registered = session.withState { $0.dragAndDrop != nil }
    if registered, dropInteraction == nil {
      let interaction = UIDropInteraction(delegate: self)
      addInteraction(interaction)
      dropInteraction = interaction
    } else if !registered, let interaction = dropInteraction {
      removeInteraction(interaction)
      dropInteraction = nil
    }
  }

  public func dropInteraction(
    _ interaction: UIDropInteraction,
    canHandle session: any UIDropSession
  ) -> Bool { self.session.withState { $0.dragAndDrop != nil } }

  public func dropInteraction(
    _ interaction: UIDropInteraction,
    sessionDidUpdate session: any UIDropSession
  ) -> UIDropProposal {
    let event = moveEvent(session)
    let mimes = Self.dragMimeTypes(session.items.map(\.itemProvider))
    let result = self.session.mutate { state in
      state.dragMove(event, mimes: mimes)
        .map { ($0, state.dragAndDrop?.clientAccepted) }
    }
    guard let (bytes, accepted) = result else {
      return UIDropProposal(operation: .forbidden)
    }
    self.session.send(.bytes(bytes))
    // Until the program answers, offer a copy.
    switch accepted {
    case .none?: return UIDropProposal(operation: .cancel)
    case .move? where session.allowsMoveOperation:
      return UIDropProposal(operation: .move)
    default: return UIDropProposal(operation: .copy)
    }
  }

  public func dropInteraction(
    _ interaction: UIDropInteraction,
    sessionDidExit session: any UIDropSession
  ) {
    if let bytes = self.session.mutate({ $0.dragLeave() }) {
      self.session.send(.bytes(bytes))
    }
  }

  /// The data is loaded before the drop is reported, so the program's
  /// requests are served from what was dropped.
  public func dropInteraction(
    _ interaction: UIDropInteraction,
    performDrop session: any UIDropSession
  ) {
    let event = moveEvent(session)
    let providers = session.items.map(\.itemProvider)
    let mimes = Self.dragMimeTypes(providers)
    let terminal = self.session
    Task {
      var items: [KittyDragAndDrop.Item] = []
      for mime in mimes {
        if let item = await Self.load(mime, from: providers) {
          items.append(item)
        }
      }
      if let bytes = terminal.mutate({ $0.dragDrop(event, items: items) }) {
        terminal.send(.bytes(bytes))
      }
    }
  }

  private func moveEvent(
    _ session: any UIDropSession
  ) -> KittyDragAndDrop.MoveEvent {
    let point = session.location(in: self)
    let cell = cell(at: point)
    let pixel = geometry.pixel(at: point)
    var operations: KittyDragAndDrop.Operations = .copy
    if session.allowsMoveOperation { operations.insert(.move) }
    return KittyDragAndDrop.MoveEvent(
      column: UInt32(cell.column),
      row: UInt32(cell.row),
      pixelX: Int32(clamping: pixel.x),
      pixelY: Int32(clamping: pixel.y),
      operations: operations
    )
  }

  /// Dragged files are offered as `text/uri-list` first.
  private static func dragMimeTypes(_ providers: [NSItemProvider]) -> [String] {
    var mimes: [String] = []
    for provider in providers {
      for identifier in provider.registeredTypeIdentifiers {
        let mime =
          UTType(identifier)?.conforms(to: .fileURL) == true
          ? "text/uri-list" : UTType(identifier)?.preferredMIMEType
        guard let mime, !mimes.contains(mime) else { continue }
        mimes.append(mime)
      }
    }
    if let i = mimes.firstIndex(of: "text/uri-list") {
      mimes.insert(mimes.remove(at: i), at: 0)
    }
    return mimes
  }

  private static func load(
    _ mime: String,
    from providers: [NSItemProvider]
  ) async -> KittyDragAndDrop.Item? {
    for provider in providers {
      for identifier in provider.registeredTypeIdentifiers {
        guard let type = UTType(identifier) else { continue }
        let isURL = type.conforms(to: .fileURL)
        guard isURL ? mime == "text/uri-list" : type.preferredMIMEType == mime
        else { continue }
        guard let data = await loadData(provider, identifier) else { continue }
        if isURL {
          guard let url = URL(dataRepresentation: data, relativeTo: nil) else {
            continue
          }
          return KittyDragAndDrop.Item(
            mime: mime,
            data: Array((url.absoluteString + "\r\n").utf8)
          )
        }
        return KittyDragAndDrop.Item(mime: mime, data: Array(data))
      }
    }
    return nil
  }

  private static func loadData(
    _ provider: NSItemProvider,
    _ identifier: String
  ) async -> Data? {
    await withCheckedContinuation { continuation in
      _ = provider.loadDataRepresentation(forTypeIdentifier: identifier) {
        data,
        _ in continuation.resume(returning: data)
      }
    }
  }
}
#endif

#if os(tvOS)
extension TerminalUIView {
  /// tvOS takes no drops.
  func dragAndDropRegistrationChanged() {}
}
#endif
