import SwiftUI

/// Saved hosts. Focus-friendly: every row is a single button, and
/// destructive actions live in a context menu (available on tvOS too).
public struct HostListView: View {
  @Bindable var model: RoamingAppModel
  @State private var editing: HostProfile?
  @State private var adding = false
  @State private var browsing: HostProfile?

  public init(model: RoamingAppModel) {
    self.model = model
  }

  public var body: some View {
    List {
      if let error = model.lastError {
        Label(error, systemImage: "exclamationmark.triangle")
          .foregroundStyle(.orange)
          .listRowBackground(Color.clear)
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
          model.open(host)
        } label: {
          VStack(alignment: .leading, spacing: 2) {
            Text(host.nickname).font(.headline)
            Text(host.endpointSummary)
              .font(.subheadline.monospaced())
              .foregroundStyle(.secondary)
            Text(host.auth.summary)
              .font(.caption)
              .foregroundStyle(.secondary)
            if model.resumableHosts.contains(host.id) {
              // Opening resumes it by session ID after fresh SSH sign-in.
              Label("Detached session — open to resume", systemImage: "arrow.uturn.forward")
                .font(.caption)
                .foregroundStyle(.tint)
            }
          }
        }
        .contextMenu {
          if model.profile.sshShell {
            Button("Open Ordinary SSH Shell") { model.open(host, kind: .ordinarySSH) }
          }
          #if !os(tvOS)
            if model.profile.sftp {
              Button("Browse Files…") { browsing = host }
            }
          #endif
          Button("Edit") { editing = host }
          Button("Delete", role: .destructive) { model.delete(host) }
        }
      }
      .listRowBackground(Color.clear)
    }
    .glassListBackground()
    .navigationTitle("Hosts")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          adding = true
        } label: {
          Label("Add Host", systemImage: "plus")
        }
        .accessibilityIdentifier("hosts.add")
        .addHostShortcut()
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
      sheet(isPresented: isPresented) {
        content().presentationBackground(.clear)
      }
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
      sheet(item: item) { item in
        content(item).presentationBackground(.clear)
      }
    #endif
  }

  /// Add/Edit Host forms.
  func hostEditorPresentation(
    adding: Binding<Bool>,
    editing: Binding<HostProfile?>,
    model: RoamingAppModel
  ) -> some View {
    self
      .adaptiveSheet(isPresented: adding) {
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
  let dismiss: () -> Void

  @State private var nickname: String
  @State private var host: String
  @State private var port: String
  @State private var username: String
  @State private var usesKey: Bool
  @State private var keyLabel: String
  @State private var error: HostProfile.ValidationError?
  /// The presenting binding alone does not always close the sheet on Mac
  /// Catalyst; dismiss through the environment as well.
  @Environment(\.dismiss) private var dismissSheet

  public init(model: RoamingAppModel, host: HostProfile?, dismiss: @escaping () -> Void) {
    self.model = model
    self.original = host
    self.dismiss = dismiss
    _nickname = State(initialValue: host?.nickname ?? "")
    _host = State(initialValue: host?.host ?? "")
    _port = State(initialValue: String(host?.port ?? 22))
    _username = State(initialValue: host?.username ?? "")
    if case .keychainKey(let label) = host?.auth {
      _usesKey = State(initialValue: true)
      _keyLabel = State(initialValue: label)
    } else {
      _usesKey = State(initialValue: false)
      _keyLabel = State(initialValue: "")
    }
  }

  public var body: some View {
    NavigationStack {
      Form {
        Section("Host") {
          TextField("Nickname", text: $nickname)
            .accessibilityIdentifier("host.nickname")
          TextField("Host name or address", text: $host)
            .plainEntry()
            .accessibilityIdentifier("host.address")
          TextField("Port", text: $port)
            .plainEntry()
            .accessibilityIdentifier("host.port")
          TextField("Username", text: $username)
            .plainEntry()
            .accessibilityIdentifier("host.username")
        }
        .listRowBackground(Color.clear)
        Section("Authentication") {
          Toggle("Use Keychain key", isOn: $usesKey)
          if usesKey {
            TextField("Key label", text: $keyLabel)
              .plainEntry()
          } else {
            Text("You will be asked for the password when connecting.")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        }
        .listRowBackground(Color.clear)
        if let error {
          Text(error.message).foregroundStyle(.red)
            .listRowBackground(Color.clear)
        }
      }
      .glassListBackground()
      .navigationTitle(original == nil ? "Add Host" : "Edit Host")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", action: close)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save", action: save)
            .accessibilityIdentifier("host.save")
        }
      }
    }
  }

  private func close() {
    dismiss()
    dismissSheet()
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
      try model.save(profile)
      close()
    } catch {
      self.error = error
    }
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
        Text(
          "The authenticity of \(prompt.host.endpointSummary) can't be established. "
            + "Verify the fingerprint on the Mac before trusting it."
        )
      case .changedKey:
        Label("Host key changed", systemImage: "exclamationmark.octagon")
          .font(.title2)
          .foregroundStyle(.red)
        Text(
          "The key for \(prompt.host.endpointSummary) differs from the trusted key. "
            + "The connection is blocked."
        )
      }
      VStack(alignment: .leading, spacing: 4) {
        Text(prompt.keyAlgorithm).font(.caption).foregroundStyle(.secondary)
        Text(prompt.fingerprint)
          .font(.body.monospaced())
          .selectableIfSupported()
          .accessibilityIdentifier("trust.fingerprint")
      }
      HStack {
        Button(prompt.kind == .changedKey ? "Close" : "Don't Trust", role: .cancel) {
          decide(.reject)
        }
        .accessibilityIdentifier("trust.reject")
        if prompt.kind == .unknownKey {
          Button("Trust") { decide(.trust) }
            .glassButtonStyle(prominent: true)
            .accessibilityIdentifier("trust.accept")
        }
      }
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .glassSurface()
    .glassButtonStyle()
  }
}

/// Password prompt for one connection. The password stays in memory for
/// this app session only; it is never saved or logged.
public struct PasswordPromptView: View {
  let prompt: PasswordPrompt
  let answer: (String?) -> Void
  @State private var password = ""

  public init(prompt: PasswordPrompt, answer: @escaping (String?) -> Void) {
    self.prompt = prompt
    self.answer = answer
  }

  public var body: some View {
    NavigationStack {
      Form {
        Section {
          SecureField("Password", text: $password)
            .textContentType(.password)
            .onSubmit(submit)
            .accessibilityIdentifier("password.field")
        } header: {
          Text(prompt.host.endpointSummary)
        } footer: {
          if prompt.isRetry {
            Text("The password was not accepted. Try again.").foregroundStyle(.red)
          } else {
            Text("Kept in memory until the app quits; never saved.")
          }
        }
        .listRowBackground(Color.clear)
      }
      .glassListBackground()
      .navigationTitle("Sign In")
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
