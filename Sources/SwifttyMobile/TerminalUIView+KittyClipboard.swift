#if canImport(UIKit)
import SwifttyCore
import UIKit
import UniformTypeIdentifiers

/// The kitty clipboard protocol (OSC 5522) against the general pasteboard.
extension TerminalUIView {
  func installKittyClipboard() {
    #if os(tvOS)
    session.mutate { state in
      state.kittyClipboardReader = nil
      state.kittyClipboardWriter = nil
    }
    #else
    let available = effectiveCapabilities
    let allowed = available.remoteClipboardWrites
    let readable = available.allows(.pasteFromClipboard)
    let contents: KittyClipboardPolicy.Contents = { mimes in
      let pasteboard = UIPasteboard.general
      return (
        Self.mimeTypes(on: pasteboard),
        mimes.compactMap { Self.content($0, on: pasteboard) }
      )
    }
    let prompt: @Sendable (KittyClipboard.ReadRequest) -> Void = {
      [weak self] request in
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          self?.promptClipboardRead(request, contents: contents)
        }
      }
    }
    session.mutate { state in
      state.kittyClipboardReader =
        readable ? KittyClipboardPolicy.reader(prompt: prompt, contents) : nil
      state.kittyClipboardWriter = KittyClipboardPolicy.writer(allowed: allowed)
      { contents in
        DispatchQueue.main.async { Self.write(contents, to: .general) }
      }
    }
    #endif
  }

  #if !os(tvOS)
  /// Asks whether a program may read the clipboard, then answers it.
  /// Without a presenter the read is denied.
  private func promptClipboardRead(
    _ request: KittyClipboard.ReadRequest,
    contents: @escaping KittyClipboardPolicy.Contents
  ) {
    let session = session
    let finish: @MainActor (KittyClipboardPolicy.Answer) -> Void = { answer in
      let result = KittyClipboardPolicy.result(
        for: request,
        answer,
        read: contents
      )
      session.mutate {
        $0.completeKittyClipboardRead(request.token, with: result)
      }
    }
    var presenter = window?.rootViewController
    while let presented = presenter?.presentedViewController {
      presenter = presented
    }
    guard let presenter else {
      finish(.deny)
      return
    }
    let alert = UIAlertController(
      title: "Allow Clipboard Access?",
      message: KittyClipboardPolicy.message(for: request),
      preferredStyle: .alert
    )
    alert.addAction(
      UIAlertAction(title: "Deny", style: .cancel) { _ in finish(.deny) }
    )
    alert.addAction(
      UIAlertAction(title: "Allow", style: .default) { _ in finish(.allow) }
    )
    if request.canRemember {
      alert.addAction(
        UIAlertAction(title: "Always Allow", style: .default) { _ in
          finish(.allowAlways)
        }
      )
    }
    presenter.present(alert, animated: true)
  }

  /// With kitty paste events on, the paste is announced instead of typed.
  func sendKittyPasteEvent() -> Bool {
    let types = Self.mimeTypes(on: pasteboard)
    guard let event = session.mutate({ $0.kittyPasteEvent(available: types) })
    else { return false }
    session.send(.bytes(event))
    return true
  }

  nonisolated static func mimeTypes(on pasteboard: UIPasteboard) -> [String] {
    var mimes: [String] = []
    if pasteboard.hasStrings { mimes.append("text/plain") }
    for type in pasteboard.types {
      guard let mime = UTType(type)?.preferredMIMEType, !mimes.contains(mime)
      else { continue }
      mimes.append(mime)
    }
    return mimes
  }

  nonisolated private static func content(
    _ mime: String,
    on pasteboard: UIPasteboard
  ) -> KittyClipboard.Content? {
    if mime == "text/plain" || mime.hasPrefix("text/plain;") {
      return pasteboard.string.map {
        KittyClipboard.Content(mime: mime, data: Array($0.utf8))
      }
    }
    guard let type = UTType(mimeType: mime),
      let data = pasteboard.data(forPasteboardType: type.identifier)
    else { return nil }
    return KittyClipboard.Content(mime: mime, data: Array(data))
  }

  private static func write(
    _ contents: [KittyClipboard.Content],
    to pasteboard: UIPasteboard
  ) {
    var item: [String: Any] = [:]
    for content in contents {
      if content.mime == "text/plain" || content.mime.hasPrefix("text/plain;") {
        item[UTType.utf8PlainText.identifier] = String(
          decoding: content.data,
          as: UTF8.self
        )
      } else if let type = UTType(mimeType: content.mime) {
        item[type.identifier] = Data(content.data)
      }
    }
    pasteboard.items = item.isEmpty ? [] : [item]
  }
  #endif
}
#endif
