#if os(macOS)
import Foundation
import TerminalHost
import Testing

struct LaunchAgentTests {
  @Test
  func `bootstrap follows the installed agent's configuration`() throws {
    let custom = LaunchAgent(
      executable: "/usr/local/libexec/swifttyd",
      configurationPath: "/Users/me/rst.json"
    )
    #expect(
      LaunchAgent.configurationPath(inPropertyList: try custom.propertyList())
        == "/Users/me/rst.json"
    )
    let plain = LaunchAgent(executable: "/usr/local/libexec/swifttyd")
    #expect(LaunchAgent.configurationPath(inPropertyList: try plain.propertyList()) == nil)
    #expect(LaunchAgent.configurationPath(inPropertyList: Data("junk".utf8)) == nil)
  }
}
#endif
