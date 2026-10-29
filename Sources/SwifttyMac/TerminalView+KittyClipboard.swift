import AppKit
import SwifttyCore
import UniformTypeIdentifiers

/// The kitty clipboard protocol (OSC 5522) against the general pasteboard.
extension TerminalView {
  func installKittyClipboard() {
    let allowed = capabilities.remoteClipboardWrites
    let readable = capabilities.allows(.pasteFromClipboard)
    let contents: KittyClipboardPolicy.Contents = { mimes in
      let pasteboard = NSPasteboard.general
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
  }

  /// Asks whether a program may read the clipboard, then answers it.
  private func promptClipboardRead(
    _ request: KittyClipboard.ReadRequest,
    contents: @escaping KittyClipboardPolicy.Contents
  ) {
    let alert = NSAlert()
    alert.messageText = "Allow Clipboard Access?"
    alert.informativeText = KittyClipboardPolicy.message(for: request)
    alert.addButton(withTitle: "Deny")
    alert.addButton(withTitle: "Allow")
    if request.canRemember { alert.addButton(withTitle: "Always Allow") }
    let session = session
    let finish: @MainActor (NSApplication.ModalResponse) -> Void = { response in
      let answer: KittyClipboardPolicy.Answer =
        switch response {
        case .alertSecondButtonReturn: .allow
        case .alertThirdButtonReturn: .allowAlways
        default: .deny
        }
      let result = KittyClipboardPolicy.result(
        for: request,
        answer,
        read: contents
      )
      session.mutate {
        $0.completeKittyClipboardRead(request.token, with: result)
      }
    }
    if let window {
      alert.beginSheetModal(for: window) { finish($0) }
    } else {
      finish(alert.runModal())
    }
  }

  /// With kitty paste events on, the paste is announced instead of typed.
  func sendKittyPasteEvent() -> Bool {
    let types = Self.mimeTypes(on: pasteboard)
    guard let event = session.mutate({ $0.kittyPasteEvent(available: types) })
    else { return false }
    session.send(.bytes(event))
    return true
  }

  nonisolated package static func mimeTypes(
    on pasteboard: NSPasteboard
  ) -> [String] {
    var mimes: [String] = []
    if pasteboard.string(forType: .string) != nil { mimes.append("text/plain") }
    for type in pasteboard.types ?? [] {
      guard let mime = UTType(type.rawValue)?.preferredMIMEType,
        !mimes.contains(mime)
      else { continue }
      mimes.append(mime)
    }
    return mimes
  }

  nonisolated package static func content(
    _ mime: String,
    on pasteboard: NSPasteboard
  ) -> KittyClipboard.Content? {
    if mime == "text/plain" || mime.hasPrefix("text/plain;") {
      return pasteboard.string(forType: .string)
        .map { KittyClipboard.Content(mime: mime, data: Array($0.utf8)) }
    }
    guard let type = UTType(mimeType: mime),
      let data = pasteboard.data(
        forType: NSPasteboard.PasteboardType(type.identifier)
      )
    else { return nil }
    return KittyClipboard.Content(mime: mime, data: Array(data))
  }

  package static func write(
    _ contents: [KittyClipboard.Content],
    to pasteboard: NSPasteboard
  ) {
    pasteboard.clearContents()
    for content in contents {
      if content.mime == "text/plain" || content.mime.hasPrefix("text/plain;") {
        pasteboard.setString(
          String(decoding: content.data, as: UTF8.self),
          forType: .string
        )
      } else if let type = UTType(mimeType: content.mime) {
        pasteboard.setData(
          Data(content.data),
          forType: NSPasteboard.PasteboardType(type.identifier)
        )
      }
    }
  }
}
