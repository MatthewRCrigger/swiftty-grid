import SwiftUI

/// Settings, grouped: the keys this device signs in with and their sync,
/// pairing with a Mac, and the Apple Watch companion. Each group appears
/// only where the platform supports it (`PlatformProfile`).
struct SettingsView: View {
  @Bindable
  var model: RoamingAppModel
  /// Connect to Mac: discovery, codes, confirmation and the chooser.
  @State
  private var connecting: ConnectSheet?
  @State
  private var adding = false
  @State
  private var editing: HostProfile?

  private var pairs: Bool {
    model.profile.nearbyDiscovery || model.profile.codeScanning
      || model.profile.codeImport
  }

  var body: some View {
    Form {
      Section("Keys & Sync") {
        NavigationLink {
          SSHKeysView(model: model)
        } label: {
          Label("SSH Keys", systemImage: "key")
        }
        .accessibilityIdentifier("settings.keys")
        if model.profile.cloudSync {
          NavigationLink {
            SyncSettingsView(model: model)
          } label: {
            Label("iCloud Sync", systemImage: "icloud")
          }
          .accessibilityIdentifier("settings.sync")
        }
      }
      .listRowBackground(Color.clear)
      if pairs { pairing }
      if model.profile.companionBridge {
        Section("Apple Watch") {
          NavigationLink {
            CompanionSettingsView(model: model)
          } label: {
            Label("Apple Watch", systemImage: "applewatch")
          }
          .accessibilityIdentifier("settings.watch")
        }
        .listRowBackground(Color.clear)
      }
    }
    .glassListBackground().navigationTitle("Settings")
    .hostEditorPresentation(adding: $adding, editing: $editing, model: model)
    .background {
      // A separate presentation anchor from the editor sheets.
      Color.clear.adaptiveSheet(item: $connecting) { sheet in
        ConnectSheetView(sheet: sheet, connecting: $connecting, model: model)
          .macSheetFrame(width: 480, height: 460)
      }
    }
  }

  private var pairing: some View {
    Section {
      if model.profile.nearbyDiscovery {
        Button("Nearby Macs", systemImage: "dot.radiowaves.left.and.right") {
          connecting = .nearby
        }
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
    } header: {
      Text("Connect to Mac")
    } footer: {
      Text(
        "Find a Mac on this network, or use the code its Connect a Device "
          + "window shows. Paired Macs appear in Hosts."
      )
    }
    .listRowBackground(Color.clear)
  }
}
