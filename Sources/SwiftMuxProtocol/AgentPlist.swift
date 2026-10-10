/// launchd job description, used both for the app bundle (SMAppService,
/// `BundleProgram`) and for development installs (`Program`).
public enum AgentPlist {
  public static func contents(
    label: String = SMX.defaultMachService,
    program: String? = nil,
    bundleProgram: String? = nil
  ) -> String {
    let programKey =
      if let program {
        "<key>Program</key>\n  <string>\(escape(program))</string>"
      } else {
        "<key>BundleProgram</key>\n  <string>\(escape(bundleProgram ?? "Contents/MacOS/swiftmux-agent"))</string>"
      }
    // Started by its Mach service, and once at login so a configured
    // roaming listener is up before any local client connects. No
    // KeepAlive: without roaming it exits at the empty-state barrier.
    // No memory-pressure exit while terminal sessions exist.
    return """
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
        <key>Label</key>
        <string>\(escape(label))</string>
        \(programKey)
        <key>MachServices</key>
        <dict>
          <key>\(escape(label))</key>
          <true/>
        </dict>
        <key>RunAtLoad</key>
        <true/>
        <key>ProcessType</key>
        <string>Interactive</string>
        <key>EnablePressuredExit</key>
        <false/>
        <key>EnableTransactions</key>
        <false/>
      </dict>
      </plist>

      """
  }

  private static func escape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
  }
}
