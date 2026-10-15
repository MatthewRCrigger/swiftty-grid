import SwiftUI

/// Saved hosts. Focus-friendly: every row is a single button, and
/// destructive actions live in a context menu (available on tvOS too).
public struct HostListView: View {
  @Bindable
  var model: RoamingAppModel
  @State
  private var editing: HostProfile?
  @State
  private var adding = false
  @State
  private var browsing: HostProfile?
  /// Connect to Mac: discovery, codes, confirmation and the chooser.
  @State
  private var connecting: ConnectSheet?

  public init(model: RoamingAppModel) { self.model = model }

  public var body: some View {
    List {
      if let error = model.lastError {
        Label(error, systemImage: "exclamationmark.triangle")
          .foregroundStyle(.orange).listRowBackground(Color.clear)
      }
      if model.hosts.isEmpty {
        ContentUnavailableView(
          "No Hosts",
          systemImage: "server.rack",
          description: Text("Add a Mac with Remote Login enabled.")
        )
        .listRowBackground(Color.clear)
      }
      ForEach(model.hosts) { host in
        Button {
          // Mac → Workspace: sign in, then pick or create a workspace.
          connecting = .choose(host)
        } label: {
          VStack(alignment: .leading, spacing: 2) {
            Text(host.nickname).font(.headline)
            Text(host.endpointSummary).font(.subheadline.monospaced())
              .foregroundStyle(.secondary)
            Text(host.auth.summary).font(.caption).foregroundStyle(.secondary)
            if model.resumableHosts.contains(host.id) {
              // Resuming still needs fresh SSH sign-in.
              Label(
                "Detached session — open to resume",
                systemImage: "arrow.uturn.forward"
              )
              .font(.caption).foregroundStyle(.tint)
            }
          }
        }
        .contextMenu {
          if let last = model.resumableSessionID(for: host) {
            // Names the remembered workspace; never creates one.
            Button(
              "Resume Last Workspace (\(last.hex.prefix(8)))",
              systemImage: "arrow.uturn.forward"
            ) { model.resumeLastWorkspace(host) }
          }
          if model.profile.sshShell {
            Button("Open Ordinary SSH Shell") {
              model.open(host, kind: .ordinarySSH)
            }
          }
          #if !os(tvOS)
          if model.profile.sftp { Button("Browse Files…") { browsing = host } }
          #endif
          Button("Edit") { editing = host }
          Button("Delete", role: .destructive) { model.delete(host) }
        }
      }
      .listRowBackground(Color.clear)
    }
    .glassListBackground().navigationTitle("Hosts")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          adding = true
        } label: {
          Label("Add Host", systemImage: "plus")
        }
        .accessibilityIdentifier("hosts.add").addHostShortcut()
      }
      if model.profile.nearbyDiscovery || model.profile.codeScanning
        || model.profile.codeImport
      {
        ToolbarItem(placement: .automatic) {
          Menu {
            if model.profile.nearbyDiscovery {
              Button("Nearby Macs", systemImage: "dot.radiowaves.left.and.right")
              { connecting = .nearby }
              .accessibilityIdentifier("connect.nearby")
            }
            if model.profile.codeScanning {
              Button("Scan Mac Code", systemImage: "qrcode.viewfinder") {
                connecting = .scan
              }
              .accessibilityIdentifier("connect.scan")
            }
            if model.profile.codeImport {
              Button("Paste Mac Code", systemImage: "doc.on.clipboard") {
                connecting = .paste
              }
              .accessibilityIdentifier("connect.paste")
            }
            Button("Enter Address Manually", systemImage: "keyboard") {
              adding = true
            }
            .accessibilityIdentifier("connect.manual")
          } label: {
            Label("Connect to Mac", systemImage: "laptopcomputer.and.iphone")
          }
          .accessibilityIdentifier("hosts.connect")
        }
      }
      if model.profile.localPTY {
        ToolbarItem(placement: .automatic) {
          Button {
            model.openLocalShell()
          } label: {
            Label("Local Shell", systemImage: "terminal")
          }
        }
      }
    }
    #if !os(tvOS)
    .adaptiveSheet(item: $browsing) { host in
      SFTPBrowserView(host: host, app: model)
      .macSheetFrame(width: 560, height: 480)
    }
    #endif
    .hostEditorPresentation(adding: $adding, editing: $editing, model: model)
    .background {
      // A separate presentation anchor from the editor sheets.
      Color.clear.adaptiveSheet(item: $connecting) { sheet in
        connectSheet(sheet).macSheetFrame(width: 480, height: 460)
      }
    }
  }

  @ViewBuilder
  private func connectSheet(_ sheet: ConnectSheet) -> some View {
    let binding = $connecting
    let select: @MainActor @Sendable (HostCandidate) -> Void = {
      binding.wrappedValue = .candidate($0)
    }
    let cancel = { connecting = nil }
    switch sheet {
    case .nearby:
      NearbyMacsView(select: select, cancel: cancel)
    case .scan:
      #if os(iOS) && !targetEnvironment(macCatalyst)
      ScanCodeView(
        select: select,
        paste: { connecting = .paste },
        cancel: cancel
      )
      #else
      PasteCodeView(select: select, cancel: cancel)
      #endif
    case .paste:
      PasteCodeView(select: select, cancel: cancel)
    case let .candidate(candidate):
      HostEditorView(
        model: model,
        host: nil,
        candidate: candidate,
        onPaired: { connecting = .choose($0) },
        dismiss: cancel
      )
    case let .choose(host):
      WorkspaceChooserView(host: host, app: model, dismiss: cancel)
    }
  }
}

extension View {
  /// A sheet, except on Mac Catalyst, where SwiftUI's programmatic sheet
  /// dismissal (Save, Cancel, Done) did not close the sheet; there the
  /// content is pushed onto the enclosing navigation stack instead, and
  /// the same dismissal pops it.
  @ViewBuilder
  func adaptiveSheet<Content: View>(
    isPresented: Binding<Bool>,
    @ViewBuilder content: @escaping () -> Content
  ) -> some View {
    #if targetEnvironment(macCatalyst)
    navigationDestination(isPresented: isPresented, destination: content)
    #else
    sheet(isPresented: isPresented) { content().presentationBackground(.clear) }
    #endif
  }

  @ViewBuilder
  func adaptiveSheet<Item: Hashable & Identifiable, Content: View>(
    item: Binding<Item?>,
    @ViewBuilder content: @escaping (Item) -> Content
  ) -> some View {
    #if targetEnvironment(macCatalyst)
    navigationDestination(item: item, destination: content)
    #else
    sheet(item: item) { item in content(item).presentationBackground(.clear) }
    #endif
  }

  /// Add/Edit Host forms.
  func hostEditorPresentation(
    adding: Binding<Bool>,
    editing: Binding<HostProfile?>,
    model: RoamingAppModel
  ) -> some View {
    self.adaptiveSheet(isPresented: adding) {
      HostEditorView(model: model, host: nil) { adding.wrappedValue = false }
        .macSheetFrame()
    }
    .adaptiveSheet(item: editing) { host in
      HostEditorView(model: model, host: host) { editing.wrappedValue = nil }
        .macSheetFrame()
    }
  }
}

/// Add/edit form for a saved host. Collects no secrets: passwords are
/// prompted at connect time and keys are referenced by Keychain label.
public struct HostEditorView: View {
  let model: RoamingAppModel
  let original: HostProfile?
  /// A discovered or scanned Mac awaiting confirmation; `nil` for
  /// ordinary add/edit.
  let candidate: HostCandidate?
  let onPaired: ((HostProfile) -> Void)?
  let dismiss: () -> Void

  @State
  private var nickname: String
  @State
  private var host: String
  @State
  private var port: String
  @State
  private var username: String
  @State
  private var usesKey: Bool
  @State
  private var keyLabel: String
  @State
  private var error: String?
  @State
  private var confirmedSource = false
  /// Explicit choice to update this saved host instead of adding one.
  @State
  private var replacing: UUID?
  @State
  private var pairing: Task<Void, Never>?
  /// The presenting binding alone does not always close the sheet on Mac
  /// Catalyst; dismiss through the environment as well.
  @Environment(\.dismiss)
  private var dismissSheet

  public init(
    model: RoamingAppModel,
    host: HostProfile?,
    candidate: HostCandidate? = nil,
    onPaired: ((HostProfile) -> Void)? = nil,
    dismiss: @escaping () -> Void
  ) {
    self.model = model
    self.original = host
    self.candidate = candidate
    self.onPaired = onPaired
    self.dismiss = dismiss
    _nickname = State(
      initialValue: host?.nickname ?? candidate?.suggestedNickname ?? ""
    )
    _host = State(initialValue: host?.host ?? candidate?.host ?? "")
    _port = State(initialValue: String(host?.port ?? candidate?.port ?? 22))
    _username = State(
      initialValue: host?.username ?? candidate?.username ?? ""
    )
    if case .keychainKey(let label) = host?.auth {
      _usesKey = State(initialValue: true)
      _keyLabel = State(initialValue: label)
    } else {
      _usesKey = State(initialValue: false)
      _keyLabel = State(initialValue: "")
    }
  }

  public var body: some View {
    if candidate != nil {
      form.modalConnectionPrompts(model)
    } else {
      form
    }
  }

  /// Saved hosts at the same address, offered only as an explicit update.
  private var matchingHosts: [HostProfile] {
    let address = host.trimmingCharacters(in: .whitespaces).lowercased()
    let number = Int(port.trimmingCharacters(in: .whitespaces))
    return model.hosts.filter {
      $0.host.lowercased() == address && $0.port == number
    }
  }

  private var form: some View {
    NavigationStack {
      Form {
        // First, so a blocked connection stays visible above the keyboard.
        if pairing != nil {
          HStack {
            ProgressView()
            Text("Verifying the Mac's SSH key and signing in…")
          }
          .listRowBackground(Color.clear)
        }
        if let error {
          Text(error).foregroundStyle(.red).listRowBackground(Color.clear)
            .accessibilityIdentifier("host.error")
        }
        if let candidate {
          CandidateSummary(
            candidate: candidate,
            confirmedSource: $confirmedSource
          )
        }
        Section("Host") {
          TextField("Nickname", text: $nickname)
            .accessibilityIdentifier("host.nickname")
          TextField("Host name or address", text: $host).plainEntry()
            .accessibilityIdentifier("host.address")
          TextField("Port", text: $port).plainEntry()
            .accessibilityIdentifier("host.port")
          TextField("Username", text: $username).plainEntry()
            .accessibilityIdentifier("host.username")
        }
        .listRowBackground(Color.clear)
        Section("Authentication") {
          Toggle("Use Keychain key", isOn: $usesKey)
          if usesKey {
            TextField("Key label", text: $keyLabel).plainEntry()
          } else {
            Text("You will be asked for the password when connecting.")
              .font(.footnote).foregroundStyle(.secondary)
          }
        }
        .listRowBackground(Color.clear)
        if candidate != nil, !matchingHosts.isEmpty {
          Section {
            Picker("Save as", selection: $replacing) {
              Text("New host").tag(UUID?.none)
              ForEach(matchingHosts) { saved in
                Text("Update \u{201C}\(saved.nickname)\u{201D}")
                  .tag(UUID?.some(saved.id))
              }
            }
          } footer: {
            Text(
              "Updating keeps that host's place in the list. Its trusted key is "
                + "never replaced: a different key still blocks the connection."
            )
          }
          .listRowBackground(Color.clear)
        }
      }
      .glassListBackground()
      .navigationTitle(
        candidate != nil
          ? "Connect to Mac" : original == nil ? "Add Host" : "Edit Host"
      )
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", action: close)
        }
        ToolbarItem(placement: .confirmationAction) {
          if candidate != nil {
            Button("Connect", action: connect)
              .disabled(
                pairing != nil
                  || (candidate?.source == .code && !confirmedSource)
              )
              .accessibilityIdentifier("host.connect")
          } else {
            Button("Save", action: save).accessibilityIdentifier("host.save")
          }
        }
      }
    }
  }

  private func close() {
    // Cancelling discards the candidate; an in-flight sign-in stops.
    pairing?.cancel()
    pairing = nil
    dismiss()
    dismissSheet()
  }

  private func draft(id: UUID) -> HostProfile {
    HostProfile(
      id: id,
      nickname: nickname.trimmingCharacters(in: .whitespaces),
      host: host.trimmingCharacters(in: .whitespaces),
      port: Int(port.trimmingCharacters(in: .whitespaces)) ?? 0,
      username: username.trimmingCharacters(in: .whitespaces),
      auth: usesKey ? .keychainKey(label: keyLabel) : .password
    )
  }

  /// Verify, trust, sign in, save; then the workspace chooser.
  private func connect() {
    guard let candidate, pairing == nil else { return }
    let profile = draft(
      id: matchingHosts.first { $0.id == replacing }?.id ?? UUID()
    )
    do { try profile.validate() } catch {
      self.error = error.message
      return
    }
    error = nil
    pairing = Task {
      defer { pairing = nil }
      do throws(PairingFailure) {
        let saved = try await model.pair(
          profile,
          expectedHostKeys: candidate.expectedHostKeys
        )
        guard !Task.isCancelled else { return }
        onPaired?(saved)
      } catch {
        guard !Task.isCancelled else { return }
        self.error = error.message
      }
    }
  }

  private func save() {
    let profile = HostProfile(
      id: original?.id ?? UUID(),
      nickname: nickname.trimmingCharacters(in: .whitespaces),
      host: host.trimmingCharacters(in: .whitespaces),
      port: Int(port.trimmingCharacters(in: .whitespaces)) ?? 0,
      username: username.trimmingCharacters(in: .whitespaces),
      auth: usesKey ? .keychainKey(label: keyLabel) : .password
    )
    do {
      guard try model.save(profile) else {
        error = model.lastError
        return
      }
      close()
    } catch { self.error = error.message }
  }
}

extension HostProfile.ValidationError {
  var message: String {
    switch self {
    case .emptyNickname: "Enter a nickname."
    case .invalidHost: "Enter a valid host name or address."
    case .invalidPort: "Port must be between 1 and 65535."
    case .invalidUsername: "Enter a valid username."
    case .invalidKeyLabel: "Enter a valid key label."
    }
  }
}

extension View {
  /// ⌘N for Add Host where hardware keyboard shortcuts exist (not tvOS).
  func addHostShortcut() -> some View {
    #if os(tvOS)
    self
    #else
    self.keyboardShortcut("n", modifiers: .command)
    #endif
  }

  /// Text selection where the platform offers it (not tvOS).
  func selectableIfSupported() -> some View {
    #if os(tvOS)
    self
    #else
    self.textSelection(.enabled)
    #endif
  }

  /// macOS sheets size to their content; a `NavigationStack` + `Form`
  /// sheet otherwise collapses to nothing while still making the window
  /// modal. Gives such sheets a usable minimum size there.
  func macSheetFrame(width: CGFloat = 460, height: CGFloat = 380) -> some View {
    #if os(macOS)
    self.frame(minWidth: width, minHeight: height)
    #else
    self
    #endif
  }

  /// Disables autocorrection and capitalization for identifiers.
  func plainEntry() -> some View {
    #if os(macOS)
    self.autocorrectionDisabled()
    #else
    self.autocorrectionDisabled().textInputAutocapitalization(.never)
    #endif
  }
}

/// Host-key trust prompt (spec §5.1). An unknown key needs an
/// explicit decision; a changed key blocks the connection outright.
public struct TrustPromptView: View {
  let prompt: TrustPrompt
  let decide: (TrustDecision) -> Void

  public init(prompt: TrustPrompt, decide: @escaping (TrustDecision) -> Void) {
    self.prompt = prompt
    self.decide = decide
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      switch prompt.kind {
      case .unknownKey:
        Label("Unknown host key", systemImage: "questionmark.diamond")
          .font(.title2)
        if prompt.matchesPairingCode {
          Label(
            "Matches the connection code you confirmed",
            systemImage: "checkmark.seal"
          )
          .foregroundStyle(.green).accessibilityIdentifier("trust.paired")
          Text(
            "Trusting stores this key for \(prompt.host.endpointSummary); "
              + "a different key will be blocked later."
          )
        } else {
          Text(
            "The authenticity of \(prompt.host.endpointSummary) can't be established. "
              + "Verify the fingerprint on the Mac before trusting it."
          )
        }
      case .changedKey:
        Label("Host key changed", systemImage: "exclamationmark.octagon")
          .font(.title2).foregroundStyle(.red)
        Text(
          "The key for \(prompt.host.endpointSummary) differs from the trusted key. "
            + "The connection is blocked."
        )
      }
      VStack(alignment: .leading, spacing: 4) {
        Text(prompt.keyAlgorithm).font(.caption).foregroundStyle(.secondary)
        Text(prompt.fingerprint).font(.body.monospaced())
          .selectableIfSupported().accessibilityIdentifier("trust.fingerprint")
      }
      HStack {
        Button(
          prompt.kind == .changedKey ? "Close" : "Don't Trust",
          role: .cancel
        ) { decide(.reject) }
        .accessibilityIdentifier("trust.reject")
        if prompt.kind == .unknownKey {
          Button("Trust") { decide(.trust) }.glassButtonStyle(prominent: true)
            .accessibilityIdentifier("trust.accept")
        }
      }
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .glassSurface().glassButtonStyle()
  }
}

/// Password prompt for one connection. The password stays in memory for
/// this app session only; it is never saved or logged.
public struct PasswordPromptView: View {
  let prompt: PasswordPrompt
  let answer: (String?) -> Void
  @State
  private var password = ""

  public init(prompt: PasswordPrompt, answer: @escaping (String?) -> Void) {
    self.prompt = prompt
    self.answer = answer
  }

  public var body: some View {
    NavigationStack {
      Form {
        Section {
          SecureField("Password", text: $password).textContentType(.password)
            .onSubmit(submit).accessibilityIdentifier("password.field")
        } header: {
          Text(prompt.host.endpointSummary)
        } footer: {
          if prompt.isRetry {
            Text("The password was not accepted. Try again.")
              .foregroundStyle(.red)
          } else {
            Text("Kept in memory until the app quits; never saved.")
          }
        }
        .listRowBackground(Color.clear)
      }
      .glassListBackground().navigationTitle("Sign In")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { answer(nil) }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Sign In", action: submit).disabled(password.isEmpty)
            .accessibilityIdentifier("password.submit")
        }
      }
    }
  }

  private func submit() {
    guard !password.isEmpty else { return }
    let value = password
    password = ""
    answer(value)
  }
}
