import AppKit
import Foundation
import ServiceManagement
import SwiftMuxProtocol

// `swiftty --swiftmux-agent register|unregister|status` manages the bundled
// SwiftMux LaunchAgent without opening windows (packaging checks, scripts).
let arguments = CommandLine.arguments
if let i = arguments.firstIndex(of: "--swiftmux-agent") {
  let service = SMAppService.agent(plistName: SMX.agentPlistName)
  func describe(_ status: SMAppService.Status) -> String {
    switch status {
    case .enabled: "enabled"
    case .requiresApproval: "requiresApproval"
    case .notFound: "notFound"
    case .notRegistered: "notRegistered"
    @unknown default: "unknown"
    }
  }
  let action = i + 1 < arguments.count ? arguments[i + 1] : "status"
  do {
    switch action {
    case "register": try service.register()
    case "unregister":
      let done = DispatchSemaphore(value: 0)
      nonisolated(unsafe) var failure: (any Error)?
      service.unregister { error in
        failure = error
        done.signal()
      }
      done.wait()
      if let failure { throw failure }
    case "status": break
    default:
      FileHandle.standardError.write(
        Data(
          "usage: swiftty --swiftmux-agent register|unregister|status\n".utf8
        )
      )
      exit(64)
    }
    print(describe(service.status))
    exit(0)
  } catch {
    print(
      "\(action) failed: \(error.localizedDescription); status \(describe(service.status))"
    )
    exit(1)
  }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
