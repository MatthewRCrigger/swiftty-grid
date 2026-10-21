import AppKit
import CoreImage
import HostConnection
import Observation
import SwiftUI

/// The connection details a device needs, as the user confirmed them.
/// Configured values are not verified runtime status.
struct ConnectionDraft: Equatable {
  var host: String
  var port: String
  var username: String
  /// A nondefault SSH port must be confirmed before it is shared.
  var portConfirmed = false

  enum Problem: Equatable {
    case invalidHost
    /// A wildcard or loopback address no other device can use.
    case unusableAddress
    case invalidPort
    case portUnconfirmed
    case invalidUsername
  }

  var portValue: Int? {
    Int(port.trimmingCharacters(in: .whitespaces))
      .flatMap { (1 ... 65_535).contains($0) ? $0 : nil }
  }

  var trimmedHost: String { host.trimmingCharacters(in: .whitespaces) }

  var needsPortConfirmation: Bool { portValue.map { $0 != 22 } ?? false }

  var problem: Problem? {
    let host = trimmedHost.lowercased()
    guard HostConnectionDescriptor.isValidHost(host) else {
      return .invalidHost
    }
    if Self.unusable.contains(host) || host.hasPrefix("127.")
      || host.hasSuffix(".localhost")
    {
      return .unusableAddress
    }
    guard let port = portValue else { return .invalidPort }
    if port != 22, !portConfirmed { return .portUnconfirmed }
    guard
      HostConnectionDescriptor.isValidUsername(
        username.trimmingCharacters(in: .whitespaces)
      )
    else { return .invalidUsername }
    return nil
  }

  private static let unusable: Set<String> = [
    "0.0.0.0", "::", "0:0:0:0:0:0:0:0", "::1", "localhost",
  ]

  /// A `.local` name or private/link-local literal works only on the
  /// local network (or a VPN the user configured to carry it).
  var isLocalOnly: Bool {
    let host = trimmedHost.lowercased()
    if host.hasSuffix(".local") { return true }
    for prefix in ["10.", "192.168.", "169.254.", "fe80:", "fd", "fc"]
    where host.hasPrefix(prefix) { return true }
    if host.hasPrefix("172."),
      let second = host.split(separator: ".").dropFirst().first
        .flatMap({ Int($0) }), (16 ... 31).contains(second)
    {
      return true
    }
    return false
  }

  /// The pairing code, only with at least one SSH host key; never an
  /// address-only code presented as verified pairing.
  func descriptor(
    name: String,
    hostKeys: [HostConnectionDescriptor.HostKey]
  ) -> HostConnectionDescriptor? {
    guard problem == nil, let port = portValue, !hostKeys.isEmpty else {
      return nil
    }
    var display = HostDiscovery.sanitizedName(name)
    while display.count > HostConnectionDescriptor.maxNameLength {
      display.removeLast()
    }
    let descriptor = HostConnectionDescriptor(
      name: HostConnectionDescriptor.isValidName(display) ? display : nil,
      host: trimmedHost,
      port: port,
      username: username.trimmingCharacters(in: .whitespaces),
      hostKeys: Array(hostKeys.prefix(HostConnectionDescriptor.maxHostKeys))
    )
    return (try? descriptor.validate()) == nil ? nil : descriptor
  }
}

extension ConnectionDraft.Problem {
  var message: LocalizedStringResource {
    switch self {
    case .invalidHost:
      .localized("Enter a host name or address other devices can resolve.")
    case .unusableAddress:
      .localized(
        "That address only refers to this Mac itself; enter one other devices can reach."
      )
    case .invalidPort: .localized("Enter the SSH port, 1–65535.")
    case .portUnconfirmed:
      .localized("Confirm that SSH listens on this nondefault port.")
    case .invalidUsername: .localized("Enter the account short name.")
    }
  }
}

/// State of the Connect a Device panel. Opening it reads configuration
/// and runs read-only checks; it creates no workspace and mints no grant.
@MainActor
@Observable
final class ConnectDeviceModel {
  var draft: ConnectionDraft {
    didSet {
      guard draft != oldValue else { return }
      // A changed endpoint withdraws the advertisement and the code; the
      // user turns them on again for the new values.
      if discoverable { setDiscoverable(false) }
      showsCode = false
    }
  }
  let computerName: String
  private(set) var hostKeys: [HostConnectionDescriptor.HostKey] = []
  private(set) var roaming: LocalConnectionInfo.RoamingConfiguration = .absent
  private(set) var sshCheck: LocalConnectionInfo.Check = .checking
  private(set) var helperCheck: LocalConnectionInfo.Check = .checking
  var showsCode = false
  private(set) var discoverable = false
  /// The discoverable toggle's binding.
  var isDiscoverable: Bool {
    get { discoverable }
    set { setDiscoverable(newValue) }
  }
  private(set) var advertisement: HostAdvertiser.State = .stopped

  @ObservationIgnored
  private let advertiser: HostAdvertiser
  @ObservationIgnored
  private var checks: Task<Void, Never>?
  @ObservationIgnored
  private let readKeys: () -> [HostConnectionDescriptor.HostKey]
  @ObservationIgnored
  private let readRoaming: () -> LocalConnectionInfo.RoamingConfiguration
  @ObservationIgnored
  private let probeSSH: @Sendable (Int) async -> LocalConnectionInfo.Check
  @ObservationIgnored
  private let probeHelper: @Sendable () async -> LocalConnectionInfo.Check

  init(
    advertiser: HostAdvertiser = HostAdvertiser(),
    host: String? = LocalConnectionInfo.localHostName(),
    username: String = LocalConnectionInfo.accountName(),
    computerName: String = LocalConnectionInfo.computerName(),
    readKeys: @escaping () -> [HostConnectionDescriptor.HostKey] = {
      LocalConnectionInfo.hostKeys()
    },
    readRoaming: @escaping () -> LocalConnectionInfo.RoamingConfiguration = {
      LocalConnectionInfo.roamingConfiguration()
    },
    probeSSH: @escaping @Sendable (Int) async -> LocalConnectionInfo.Check = {
      await LocalConnectionInfo.probeSSH(port: $0)
    },
    probeHelper: @escaping @Sendable () async -> LocalConnectionInfo.Check = {
      await LocalConnectionInfo.helperStatus()
    }
  ) {
    self.advertiser = advertiser
    self.computerName = computerName
    self.draft = ConnectionDraft(
      host: host ?? "",
      port: "22",
      username: username
    )
    self.readKeys = readKeys
    self.readRoaming = readRoaming
    self.probeSSH = probeSSH
    self.probeHelper = probeHelper
    advertiser.onChange = { [weak self] state in self?.advertisement = state }
  }

  /// Re-reads configuration and re-runs the local checks.
  func refresh() {
    hostKeys = readKeys()
    roaming = readRoaming()
    sshCheck = .checking
    helperCheck = .checking
    checks?.cancel()
    let port = draft.portValue ?? 22
    checks = Task { [weak self, probeSSH, probeHelper] in
      async let ssh = probeSSH(port)
      async let helper = probeHelper()
      let (sshResult, helperResult) = await (ssh, helper)
      guard let self, !Task.isCancelled else { return }
      self.sshCheck = sshResult
      self.helperCheck = helperResult
    }
  }

  var descriptor: HostConnectionDescriptor? {
    draft.descriptor(name: computerName, hostKeys: hostKeys)
  }

  /// Advertises the confirmed SSH port while the panel is open.
  func setDiscoverable(_ on: Bool) {
    if on {
      guard draft.problem == nil, let port = draft.portValue else { return }
      discoverable = true
      advertiser.start(name: computerName, port: UInt16(port))
    } else {
      discoverable = false
      advertiser.stop()
    }
  }

  /// Closing the panel withdraws the registration; nothing else changes.
  func close() {
    checks?.cancel()
    checks = nil
    setDiscoverable(false)
    showsCode = false
  }
}

// MARK: - Window

/// Terminal Service › Connect a Device…: one panel window.
@MainActor
final class ConnectDevicePanelController: NSWindowController, NSWindowDelegate {
  let model: ConnectDeviceModel

  init(model: ConnectDeviceModel = ConnectDeviceModel()) {
    self.model = model
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered,
      defer: true
    )
    window.title = "Connect a Device"
    window.isReleasedWhenClosed = false
    window.contentViewController = NSHostingController(
      rootView: ConnectDeviceView(model: model)
    )
    super.init(window: window)
    window.delegate = self
    window.center()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  func present() {
    model.refresh()
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
  }

  func windowWillClose(_ notification: Notification) { model.close() }
}

/// The panel, one view per section: typing in the connection details
/// redraws only the sections that read the draft.
struct ConnectDeviceView: View {
  @Bindable
  var model: ConnectDeviceModel

  var body: some View {
    Form {
      ConnectionDetailsSection(model: model)
      RoamingEndpointSection(roaming: model.roaming)
      ConnectStatusSection(model: model)
      HostKeysSection(model: model)
      DiscoverySection(model: model)
    }
    .formStyle(.grouped).frame(minWidth: 480, minHeight: 560)
  }
}

private struct ConnectionDetailsSection: View {
  @Bindable
  var model: ConnectDeviceModel

  var body: some View {
    Section {
      TextField(.localized("SSH host name or address"), text: $model.draft.host)
        .accessibilityIdentifier("connect.host")
      TextField(.localized("SSH port"), text: $model.draft.port)
        .accessibilityIdentifier("connect.port")
      if model.draft.needsPortConfirmation {
        Toggle(isOn: $model.draft.portConfirmed) {
          Text(
            "SSH listens on port \(model.draft.port) on this Mac",
            bundle: #bundle
          )
        }
        .accessibilityIdentifier("connect.confirmPort")
      }
      TextField(.localized("Account name"), text: $model.draft.username)
      if let problem = model.draft.problem {
        Text(problem.message).foregroundStyle(.red).font(.footnote)
      } else if model.draft.isLocalOnly {
        Text(
          """
          \(model.draft.trimmedHost) works only on this local network (or a \
          VPN you configured to carry it), not over cellular. For other \
          networks, enter an address or DNS name reachable from there.
          """,
          bundle: #bundle
        )
        .font(.footnote).foregroundStyle(.secondary)
      }
    } header: {
      Text("Connection details", bundle: #bundle)
    } footer: {
      Text(
        "Configured values; shown to devices as entered. Nothing on this Mac changes.",
        bundle: #bundle
      )
    }
  }
}

private struct RoamingEndpointSection: View {
  let roaming: LocalConnectionInfo.RoamingConfiguration

  var body: some View {
    Section(.localized("Roaming endpoint (configured)")) {
      switch roaming {
      case let .configured(endpoint):
        LabeledContent(
          .localized("Advertised"),
          value: "\(endpoint.advertisedHost):\(endpoint.port) UDP"
        )
        Text(
          """
          Devices receive this address after SSH sign-in. It must be reachable \
          from them over UDP; a local name may not work on other networks.
          """,
          bundle: #bundle
        )
        .font(.footnote).foregroundStyle(.secondary)
      case .absent:
        Text(
          """
          Roaming is not configured. Ordinary SSH still works. To set it up, \
          run Scripts/install.sh --roaming --host <address> and restart Swiftty.
          """,
          bundle: #bundle
        )
        .font(.footnote)
      case .unreadable:
        Text(
          "The roaming configuration file could not be read.",
          bundle: #bundle
        )
        .font(.footnote).foregroundStyle(.orange)
      }
    }
  }
}

private struct ConnectStatusSection: View {
  let model: ConnectDeviceModel

  var body: some View {
    Section {
      check(.localized("SSH"), model.sshCheck)
      check(.localized("Roaming helper"), model.helperCheck)
      if case .unavailable = model.sshCheck {
        Text(
          """
          Turn on System Settings › General › Sharing › Remote Login for this \
          account. Swiftty does not change it for you.
          """,
          bundle: #bundle
        )
        .font(.footnote).foregroundStyle(.secondary)
      }
      Button(.localized("Check Again")) { model.refresh() }
    } header: {
      Text("Status (checked on this Mac)", bundle: #bundle)
    }
  }

  private func check(
    _ title: LocalizedStringResource,
    _ check: LocalConnectionInfo.Check
  ) -> some View {
    LabeledContent(title) {
      switch check {
      case .checking: ProgressView().controlSize(.small)
      case let .ok(text):
        Label(text, systemImage: "checkmark.circle").foregroundStyle(.green)
      case let .unavailable(text):
        Label(text, systemImage: "xmark.circle").foregroundStyle(.orange)
      }
    }
  }
}

private struct HostKeysSection: View {
  @Bindable
  var model: ConnectDeviceModel

  var body: some View {
    Section {
      if model.hostKeys.isEmpty {
        Text(
          """
          This Mac's SSH host public keys could not be read, so no pairing code \
          is offered. Enter the details above on the device instead and \
          compare the fingerprint when it asks.
          """,
          bundle: #bundle
        )
        .font(.footnote)
      } else {
        ForEach(model.hostKeys, id: \.sha256) { key in
          VStack(alignment: .leading) {
            Text(key.algorithm).font(.caption).foregroundStyle(.secondary)
            Text(key.sha256).font(.caption.monospaced()).textSelection(.enabled)
          }
        }
      }
      Toggle(.localized("Show Pairing Code"), isOn: $model.showsCode)
        .disabled(model.descriptor == nil)
        .accessibilityIdentifier("connect.showCode")
      if model.showsCode, let descriptor = model.descriptor,
        let text = try? descriptor.encodedString()
      {
        PairingCodeView(text: text)
      }
    } header: {
      Text("SSH host keys", bundle: #bundle)
    }
  }
}

private struct DiscoverySection: View {
  @Bindable
  var model: ConnectDeviceModel

  var body: some View {
    Section {
      Toggle(
        .localized("Make Discoverable While This Panel Is Open"),
        isOn: $model.isDiscoverable
      )
      .disabled(model.draft.problem != nil)
      .accessibilityIdentifier("connect.discoverable")
      Text(advertisementText).font(.footnote).foregroundStyle(.secondary)
    } footer: {
      Text(
        """
        Advertises only that a Swiftty Mac is here and its SSH port, on the \
        local network. Closing this panel stops it; workspaces keep running.
        """,
        bundle: #bundle
      )
    }
  }

  /// Localized plain text: it names this Mac as the system reports it.
  private var advertisementText: String {
    switch model.advertisement {
    case .stopped: String(localized: "Not discoverable.", bundle: #bundle)
    case .registering: String(localized: "Registering…", bundle: #bundle)
    case let .advertising(name, port):
      String(
        localized:
          "Discoverable as \u{201C}\(name)\u{201D} (SSH port \(port)).",
        bundle: #bundle
      )
    case .denied:
      String(
        localized: """
          Local Network access for Swiftty is off. Allow it in System Settings › \
          Privacy & Security › Local Network, then turn this on again.
          """,
        bundle: #bundle
      )
    case let .failed(code):
      String(
        localized: "Could not advertise (DNS-SD error \(code)).",
        bundle: #bundle
      )
    }
  }
}

/// The pairing code as a QR image, plus an explicit copy for pasting.
struct PairingCodeView: View {
  let text: String

  var body: some View {
    VStack(spacing: 8) {
      if let image = Self.cachedQRImage(text) {
        Image(nsImage: image).interpolation(.none).resizable()
          .frame(width: 220, height: 220)
          .accessibilityLabel(Text("Pairing code", bundle: #bundle))
      }
      Button(.localized("Copy Code")) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
      }
      Text(
        """
        Scan with the iPhone or iPad app (Connect to Mac › Scan Mac Code). The \
        code has no password or token; the device still signs in over SSH.
        """,
        bundle: #bundle
      )
      .font(.footnote).foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity)
  }

  /// The last code's image. Rendering synchronously keeps the first frame
  /// complete; the cache keeps redraws from running the CIFilter again.
  private static var lastImage: (text: String, image: NSImage?)?

  private static func cachedQRImage(_ text: String) -> NSImage? {
    if let lastImage, lastImage.text == text { return lastImage.image }
    let image = qrImage(text)
    lastImage = (text, image)
    return image
  }

  static func qrImage(_ text: String) -> NSImage? {
    guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
    filter.setValue(Data(text.utf8), forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let output = filter.outputImage else { return nil }
    let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
    let rep = NSCIImageRep(ciImage: scaled)
    let image = NSImage(size: rep.size)
    image.addRepresentation(rep)
    return image
  }
}
