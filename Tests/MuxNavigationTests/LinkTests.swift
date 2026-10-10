import Foundation
import MuxNavigation
import SwiftMuxProtocol
import Testing

@Suite("Attention links")
struct LinkTests {
  let config = AttentionLinkConfiguration(associatedDomains: ["Links.Example.invalid"])

  func reject(_ text: String) -> AttentionLink.Rejection? {
    do {
      _ = try AttentionLink.parse(text, configuration: config)
      return nil
    } catch { return error }
  }

  @Test func customSchemeRoundTrip() throws {
    let d = sampleDestination()
    let url = AttentionLink.customURL(for: d)
    #expect(url.absoluteString.hasPrefix("swiftty://attention/open?ref="))
    #expect(try AttentionLink.parse(url, configuration: config) == d)
    // Scheme and host compare case-insensitively.
    let upper = url.absoluteString.replacingOccurrences(of: "swiftty://attention", with: "SWIFTTY://Attention")
    #expect(try AttentionLink.parse(upper, configuration: config) == d)
  }

  @Test func universalLinkRoundTrip() throws {
    let d = sampleDestination(tab: false)
    let url = try #require(
      AttentionLink.universalLink(for: d, domain: "links.example.invalid", configuration: config)
    )
    #expect(url.absoluteString.hasPrefix("https://links.example.invalid/a/"))
    #expect(try AttentionLink.parse(url, configuration: config) == d)
    #expect(
      AttentionLink.universalLink(for: d, domain: "evil.example", configuration: config) == nil
    )
  }

  @Test func universalLinksOffWithoutConfiguredDomain() {
    let d = sampleDestination()
    let url = "https://links.example.invalid/a/\(AttentionLocator.encode(d))"
    #expect(throws: AttentionLink.Rejection.unknownDomain) {
      try AttentionLink.parse(url, configuration: AttentionLinkConfiguration())
    }
    #expect(AttentionLinkConfiguration(infoDictionary: nil).associatedDomains.isEmpty)
    #expect(
      AttentionLinkConfiguration(
        infoDictionary: ["SwifttyAssociatedDomains": ["ok.example", "bad domain", ""]]
      ).associatedDomains == ["ok.example"]
    )
  }

  @Test func rejectsEverythingElse() {
    let locator = AttentionLocator.encode(sampleDestination())
    let cases: [(String, AttentionLink.Rejection?)] = [
      ("http://links.example.invalid/a/\(locator)", .unsupportedScheme),
      ("ssh://attention/open?ref=\(locator)", .unsupportedScheme),
      ("file:///a/\(locator)", .unsupportedScheme),
      ("javascript:alert(1)", .unsupportedScheme),
      ("https://evil.example/a/\(locator)", .unknownDomain),
      ("https://links.example.invalid.evil.example/a/\(locator)", .unknownDomain),
      ("https://user:pw@links.example.invalid/a/\(locator)", .unexpectedComponent),
      ("https://links.example.invalid:8443/a/\(locator)", .unexpectedComponent),
      ("https://links.example.invalid/a/\(locator)#x", .unexpectedComponent),
      ("https://links.example.invalid/a/\(locator)?host=10.0.0.1", .unexpectedQuery),
      ("https://links.example.invalid/a/\(locator)/x", .unexpectedPath),
      ("https://links.example.invalid/b/\(locator)", .unexpectedPath),
      ("https://links.example.invalid/a/", .invalidLocator(.empty)),
      ("swiftty://attention/open?ref=\(locator)&ref=\(locator)", .unexpectedQuery),
      ("swiftty://attention/open?ref=\(locator)&host=evil.example", .unexpectedQuery),
      ("swiftty://attention/open?host=evil.example&ref=\(locator)", .unexpectedQuery),
      ("swiftty://attention/open?ref=", .invalidLocator(.empty)),
      ("swiftty://attention/open", .unexpectedQuery),
      ("swiftty://attention/open?", .unexpectedQuery),
      ("swiftty://attention/close?ref=\(locator)", .unexpectedPath),
      ("swiftty://attention/open/x?ref=\(locator)", .unexpectedPath),
      ("swiftty://evil.example/open?ref=\(locator)", .unexpectedPath),
      ("swiftty:attention/open?ref=\(locator)", .unexpectedPath),
      ("swiftty://attention:22/open?ref=\(locator)", .unexpectedComponent),
      ("swiftty://me@attention/open?ref=\(locator)", .unexpectedComponent),
      ("swiftty://attention/open?ref=%41\(locator)", nil),
      ("swiftty://attention/open?ref=\(locator) ", .malformedURL),
      ("swiftty://attention/open?ref=\(locator)\n", .malformedURL),
      ("swiftty://attention/open?ref=x\(String(repeating: "A", count: 2100))", .tooLong),
      ("", .malformedURL),
      // An empty port parses as no port.
      ("swiftty://attention:/open?ref=\(locator)", .unexpectedComponent),
    ]
    for (text, expected) in cases {
      let result = reject(text)
      #expect(result != nil, "accepted \(text)")
      if let expected { #expect(result == expected, "\(text)") }
    }
  }

  @Test func randomMutationsNeverEscapeValidation() {
    let base = AttentionLink.customURL(for: sampleDestination()).absoluteString
    let noise = Array("%&=?#/:@ .ABCxyz019-_\u{0}é")
    var rng = SystemRandomNumberGenerator()
    for _ in 0..<3000 {
      var chars = Array(base)
      for _ in 0..<Int.random(in: 1...3, using: &rng) {
        let i = Int.random(in: 0..<chars.count, using: &rng)
        switch Int.random(in: 0..<3, using: &rng) {
        case 0: chars[i] = noise.randomElement(using: &rng)!
        case 1: chars.insert(noise.randomElement(using: &rng)!, at: i)
        default: if chars.count > 1 { chars.remove(at: i) }
        }
      }
      let text = String(chars)
      if let d = try? AttentionLink.parse(text, configuration: config) {
        // Anything accepted is the canonical spelling of a valid locator.
        #expect(d.isValid)
        #expect(
          AttentionLink.customURL(for: d).absoluteString.lowercased() == text.lowercased(),
          "accepted non-canonical \(TestFixtureText(text))"
        )
      }
    }
  }

  /// URLs and locators contain only identifiers: never the endpoint,
  /// username, nickname or credentials of the host configuration.
  @Test func linksCarryNoSecrets() throws {
    let secrets = [
      "mac-mini.internal", "10.0.0.7", "alice", "hunter2", "Office Mac",
      "ssh-ed25519", "BEGIN OPENSSH", "agent", "Build", "approve", "rm -rf",
    ]
    var d = sampleDestination(path: "job")
    d.localHostProfileID = UUID()
    let item = sampleItem(for: d, message: "hunter2 rm -rf")
    let fromItem = AttentionDestination(hostProfileID: d.localHostProfileID, item: item)
    let texts = [
      AttentionLocator.encode(fromItem),
      AttentionLink.customURL(for: fromItem).absoluteString,
      try #require(
        AttentionLink.universalLink(
          for: fromItem,
          domain: "links.example.invalid",
          configuration: config
        )
      ).absoluteString,
    ]
    for text in texts {
      for secret in secrets {
        #expect(!text.lowercased().contains(secret.lowercased()), "\(secret) in \(text)")
      }
      // Decoded bytes hold no printable run longer than the record path.
      let locator = text.split(separator: "/").last.map(String.init) ?? text
      let token = locator.components(separatedBy: "ref=").last!
      if let bytes = Data(base64Encoded: base64(token)) {
        let ascii = String(decoding: bytes, as: UTF8.self)
        for secret in secrets { #expect(!ascii.contains(secret)) }
      }
    }
    #expect(texts[1].utf8.count <= AttentionLinkConfiguration.maxURLBytes)
  }
}

/// Escapes controls so a failing fixture cannot affect the terminal.
private func TestFixtureText(_ s: String) -> String {
  s.unicodeScalars.map { $0.value < 0x20 || $0.value == 0x7F ? "\\u{\(String($0.value, radix: 16))}" : String($0) }.joined()
}
