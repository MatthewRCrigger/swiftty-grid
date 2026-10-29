/// How surfaces serve the kitty clipboard protocol (OSC 5522). Reads of
/// what the user handed over (a paste event's follow-up read, a listing
/// of types, a remembered password) are served at once; any other read
/// asks the user through `prompt`, or is denied without one. Writes follow
/// the same policy as OSC 52. No platform here has a primary selection,
/// so those requests are unsupported.
public enum KittyClipboardPolicy {
  /// The user's answer to a read prompt.
  public enum Answer: Sendable {
    case deny, allow
    /// Allow, and skip the prompt for this program's password.
    case allowAlways
  }

  public typealias Contents =
    @Sendable (_ mimes: [String]) -> (
      available: [String], contents: [KittyClipboard.Content]
    )

  /// `read` returns the available types and the requested contents.
  /// `prompt` asks the user on its own schedule and must then complete the
  /// read through `TerminalState.completeKittyClipboardRead`, using
  /// `result(for:_:read:)`.
  public static func reader(
    prompt: (@Sendable (KittyClipboard.ReadRequest) -> Void)? = nil,
    _ read: @escaping Contents
  ) -> KittyClipboard.Reader {
    { request in
      guard !request.primary else { return .unsupported }
      guard request.granted || request.mimes.isEmpty else {
        guard let prompt else { return .denied }
        prompt(request)
        return .deferred
      }
      return result(for: request, .allow, read: read)
    }
  }

  public static func result(
    for request: KittyClipboard.ReadRequest,
    _ answer: Answer,
    read: Contents
  ) -> KittyClipboard.ReadResult {
    guard answer != .deny else { return .denied }
    let (available, contents) = read(request.mimes)
    return .success(
      available: available,
      contents: contents,
      remember: answer == .allowAlways && request.canRemember
    )
  }

  /// The prompt's message, naming the program when it gave a name.
  public static func message(for request: KittyClipboard.ReadRequest) -> String
  { readMessage(name: request.name, mimes: request.mimes) }

  public static func readMessage(name: String, mimes: [String]) -> String {
    "\(program(name)) wants to read the clipboard "
      + "(\(mimes.joined(separator: ", ")))."
  }

  public static func writeMessage(name: String, mimes: [String]) -> String {
    "\(program(name)) wants to replace the clipboard "
      + "(\(mimes.joined(separator: ", ")))."
  }

  private static func program(_ name: String) -> String {
    name.isEmpty ? "A program" : "“\(name)”"
  }

  public static func writer(
    allowed: Bool,
    _ write: @escaping @Sendable ([KittyClipboard.Content]) -> Void
  ) -> KittyClipboard.Writer {
    { request in
      guard !request.primary else { return .unsupported }
      guard allowed else { return .denied }
      write(request.contents)
      return .success(remember: false)
    }
  }
}
