import Foundation
import HostConnection
import SwiftUI

/// A Mac the user is about to connect to, from Nearby Macs or a
/// connection code. Temporary: it is not a saved host, its expected keys
/// are not trusted keys, and creating one connects to nothing
/// (spec.connection-setup.md D1, D4). Cancellation discards it.
public struct HostCandidate: Hashable, Identifiable, Sendable {
  public enum Source: Hashable, Sendable {
    /// Found by Bonjour: a name and a resolved address, nothing more.
    case nearby
    /// Decoded from a connection code the Mac displayed.
    case code
  }

  public let id = UUID()
  public var source: Source
  /// Display name only.
  public var name: String
  public var host: String
  public var port: Int
  public var username: String
  /// Expected SSH host keys from a code; empty for a nearby result.
  public var hostKeys: [HostConnectionDescriptor.HostKey]

  init(nearbyName: String, host: String, port: Int) {
    source = .nearby
    name = nearbyName
    self.host = host
    self.port = port
    username = ""
    hostKeys = []
  }

  init(descriptor: HostConnectionDescriptor) {
    source = .code
    name = descriptor.name ?? descriptor.host
    host = descriptor.host
    port = descriptor.port
    username = descriptor.username
    hostKeys = descriptor.hostKeys
  }

  /// Fingerprints SSH verification must enforce, for a code.
  var expectedHostKeys: Set<String>? {
    source == .code ? Set(hostKeys.map(\.sha256)) : nil
  }

  /// A valid default nickname derived from the display name.
  var suggestedNickname: String {
    var text = HostDiscovery.sanitizedName(name)
    while text.count > HostProfile.maxNicknameLength { text.removeLast() }
    return text.isEmpty ? host : text
  }
}

/// Why pairing stopped. Messages carry no secrets.
enum PairingFailure: Error, Equatable {
  case invalid(HostProfile.ValidationError)
  case ssh(SSHAccessError)
  case notSaved(String)

  var message: String {
    switch self {
    case let .invalid(error): error.message
    case let .ssh(error): "\(error.title). \(error.detail)"
    case let .notSaved(reason): reason
    }
  }
}

extension RoamingAppModel {
  /// Completes a confirmed candidate: SSH host-key verification (the
  /// code's keys first, before any credential, for known and unknown
  /// keys alike), explicit trust of an unknown key, sign-in, then saving
  /// the profile. Opens no workspace and acquires no lease; the caller
  /// shows the workspace chooser next.
  func pair(
    _ profile: HostProfile,
    expectedHostKeys: Set<String>?,
    access: SSHAccess? = nil
  ) async throws(PairingFailure) -> HostProfile {
    do { try profile.validate() } catch { throw .invalid(error) }
    do {
      let connection = try await (access ?? ssh).connect(
        profile,
        interactive: true,
        expectedHostKeys: expectedHostKeys
      )
      await connection.close()
    } catch { throw .ssh(error) }
    guard !Task.isCancelled else { throw .ssh(.cancelled) }
    let saved: Bool
    do { saved = try save(profile) } catch { throw .invalid(error) }
    guard saved else {
      throw .notSaved(lastError ?? "The host could not be saved.")
    }
    return profile
  }
}

/// The host list's Connect to Mac presentations, one sheet at a time.
enum ConnectSheet: Identifiable, Hashable {
  case nearby
  case scan
  case paste
  case candidate(HostCandidate)
  case choose(HostProfile)

  var id: String {
    switch self {
    case .nearby: "nearby"
    case .scan: "scan"
    case .paste: "paste"
    case let .candidate(candidate): "candidate-\(candidate.id)"
    case let .choose(host): "choose-\(host.id)"
    }
  }
}

// MARK: - Nearby Macs

/// Lists Macs advertising `_swiftty._tcp`. Browsing starts when this
/// appears and stops when it disappears or the app is backgrounded.
struct NearbyMacsView: View {
  @State
  private var browser = NearbyMacBrowser()
  let select: @MainActor @Sendable (HostCandidate) -> Void
  let cancel: () -> Void
  @Environment(\.scenePhase)
  private var scenePhase

  var body: some View {
    NavigationStack {
      List {
        status
        ForEach(browser.candidates) { candidate in
          Button {
            browser.choose(candidate, then: select)
          } label: {
            HStack {
              Label(candidate.displayName, systemImage: "desktopcomputer")
              Spacer()
              if browser.resolving == candidate.id { ProgressView() }
            }
          }
          .disabled(browser.resolving != nil)
          .accessibilityIdentifier("nearby.candidate")
        }
        .listRowBackground(Color.clear)
        if let error = browser.resolveError {
          Label(error, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.orange).listRowBackground(Color.clear)
        }
      }
      .glassListBackground().navigationTitle("Nearby Macs")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", action: close)
        }
      }
    }
    .onAppear { browser.start() }
    .onDisappear { browser.stop() }
    .onChange(of: scenePhase) { _, phase in
      // `.inactive` covers the system permission alert: keep browsing.
      switch phase {
      case .background: browser.stop()
      case .active: browser.start()
      default: break
      }
    }
  }

  @ViewBuilder
  private var status: some View {
    switch browser.state {
    case .idle, .searching:
      HStack {
        ProgressView()
        Text("Looking for Macs with Connect a Device open…")
          .foregroundStyle(.secondary)
      }
      .listRowBackground(Color.clear)
    case .results:
      EmptyView()
    case .noResults:
      VStack(alignment: .leading, spacing: 6) {
        Text("No Macs found yet").font(.headline)
        Text(
          "On the Mac, choose Terminal Service › Connect a Device… and turn on "
            + "Make Discoverable. Both devices must be on the same local network."
        )
        .font(.footnote).foregroundStyle(.secondary)
      }
      .listRowBackground(Color.clear)
    case .denied:
      VStack(alignment: .leading, spacing: 8) {
        Label("Local Network access is off", systemImage: "hand.raised")
          .font(.headline)
        Text(
          "Allow Roaming SSH in Settings › Privacy & Security › Local Network, "
            + "then try again. You can still enter an address or scan a code."
        )
        .font(.footnote).foregroundStyle(.secondary)
        Button("Try Again") { browser.restart() }
      }
      .listRowBackground(Color.clear).accessibilityIdentifier("nearby.denied")
    case let .failed(message):
      VStack(alignment: .leading, spacing: 8) {
        Label(message, systemImage: "exclamationmark.triangle")
        Button("Try Again") { browser.restart() }
      }
      .listRowBackground(Color.clear)
    }
  }

  private func close() {
    browser.stop()
    cancel()
  }
}

// MARK: - Paste a code

/// The camera-free way to enter a connection code. The pasteboard is
/// read only when the user pastes; nothing is inspected automatically.
struct PasteCodeView: View {
  let select: (HostCandidate) -> Void
  let cancel: () -> Void
  @State
  private var text = ""
  @State
  private var error: String?

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("Connection code", text: $text, axis: .vertical)
            .lineLimit(3 ... 8).plainEntry()
            .accessibilityIdentifier("paste.code")
          #if !os(tvOS)
          PasteButton(payloadType: String.self) { strings in
            guard let first = strings.first else { return }
            text = String(first.prefix(HostConnectionDescriptor.maxBytes + 1))
          }
          #endif
        } footer: {
          Text(
            "On the Mac, open Terminal Service › Connect a Device… and copy the "
              + "pairing code. It contains no password."
          )
        }
        .listRowBackground(Color.clear)
        if let error {
          Text(error).foregroundStyle(.red).listRowBackground(Color.clear)
        }
      }
      .glassListBackground().navigationTitle("Paste Mac Code")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", action: cancel)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Continue", action: decode).disabled(text.isEmpty)
            .accessibilityIdentifier("paste.continue")
        }
      }
    }
  }

  private func decode() {
    // Typing a code (rather than pasting it) gets smart punctuation; map
    // only curly double quotes back. The decoder stays strict otherwise.
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "\u{201C}", with: "\"")
      .replacingOccurrences(of: "\u{201D}", with: "\"")
    do {
      select(HostCandidate(descriptor: try HostConnectionDescriptor.decode(trimmed)))
    } catch { self.error = error.message }
  }
}

extension HostConnectionDescriptor.DecodingError {
  var message: String {
    switch self {
    case .tooLarge: "That is too long to be a Swiftty connection code."
    case .malformed, .unsupportedKind:
      "That is not a Swiftty connection code."
    case .unsupportedVersion:
      "This code needs a newer version of the app."
    case .unknownField:
      "The code contains fields this app does not accept."
    case .invalidName: "The code's Mac name is not valid."
    case .invalidHost: "The code's host name or address is not valid."
    case .invalidPort: "The code's SSH port is not valid."
    case .invalidUsername: "The code's account name is not valid."
    case .invalidHostKeys: "The code's SSH key fingerprints are not valid."
    }
  }
}

// MARK: - Candidate confirmation

/// Shows what a candidate claims, before anything connects.
struct CandidateSummary: View {
  let candidate: HostCandidate
  @Binding
  var confirmedSource: Bool

  var body: some View {
    switch candidate.source {
    case .code:
      Section {
        ForEach(candidate.hostKeys, id: \.sha256) { key in
          VStack(alignment: .leading, spacing: 2) {
            Text(key.algorithm).font(.caption).foregroundStyle(.secondary)
            Text(key.sha256).font(.caption.monospaced()).selectableIfSupported()
          }
        }
        Toggle(
          "This code came from the Mac I want to connect to",
          isOn: $confirmedSource
        )
        .accessibilityIdentifier("candidate.confirmSource")
      } header: {
        Text("Expected SSH host keys")
      } footer: {
        Text(
          "The Mac must present one of these keys before any password is sent. "
            + "A different key blocks the connection."
        )
      }
      .listRowBackground(Color.clear)
    case .nearby:
      Section {
        Label(
          "Found on this network as \u{201C}\(candidate.name)\u{201D}",
          systemImage: "dot.radiowaves.left.and.right"
        )
      } footer: {
        Text(
          "A network name is not proof of identity. Compare the SSH key "
            + "fingerprint with the Mac's Connect a Device panel when asked."
        )
      }
      .listRowBackground(Color.clear)
    }
  }
}
