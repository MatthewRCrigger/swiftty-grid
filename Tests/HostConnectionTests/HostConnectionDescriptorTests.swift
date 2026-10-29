import Foundation
import HostConnection
import Testing
import TestSupport

/// Pairing-code codec bounds (spec.connection-setup.md acceptance T6).
struct HostConnectionDescriptorTests {
  /// A syntactically valid fingerprint: 32 zero bytes. Not a real key.
  static let zeroPrint = "SHA256:" + String(repeating: "A", count: 43)
  static let otherPrint =
    "SHA256:"
    + Data(repeating: 0x5A, count: 32).base64EncodedString()
    .replacingOccurrences(of: "=", with: "")

  static let sample = HostConnectionDescriptor(
    name: "My MacBook",
    host: "macbook.local",
    port: 22,
    username: "chris",
    hostKeys: [.init(algorithm: "ssh-ed25519", sha256: zeroPrint)]
  )

  /// Serializes a fixture; an unserializable one decodes as malformed.
  private func json(_ object: [String: Any]) -> Data {
    (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
  }

  private func object(
    name: Any? = "My MacBook",
    host: Any = "macbook.local",
    port: Any = 22,
    username: Any = "chris",
    keys: Any = [["algorithm": "ssh-ed25519", "sha256": zeroPrint]],
    extra: [String: Any] = [:],
    sshExtra: [String: Any] = [:]
  ) -> [String: Any] {
    var ssh: [String: Any] = ["host": host, "port": port, "username": username]
    ssh.merge(sshExtra) { $1 }
    var root: [String: Any] = [
      "kind": "swiftty-host", "version": 1, "ssh": ssh, "hostKeys": keys,
    ]
    if let name { root["name"] = name }
    root.merge(extra) { $1 }
    return root
  }

  @Test
  func roundTrips() throws {
    let data = try Self.sample.encoded()
    #expect(data.count <= HostConnectionDescriptor.maxBytes)
    #expect(try HostConnectionDescriptor.decode(data) == Self.sample)
    let text = try Self.sample.encodedString()
    #expect(try HostConnectionDescriptor.decode(text) == Self.sample)
    #expect(!text.contains("\n"))
  }

  @Test
  func roundTripsFourKeysAndIPLiterals() throws {
    for host in ["192.168.1.20", "fd00::1", "mac-mini.example.com"] {
      let descriptor = HostConnectionDescriptor(
        name: nil,
        host: host,
        port: 2222,
        username: "first.last",
        hostKeys: [
          .init(algorithm: "ssh-ed25519", sha256: Self.zeroPrint),
          .init(algorithm: "ecdsa-sha2-nistp256", sha256: Self.otherPrint),
        ]
      )
      #expect(
        try HostConnectionDescriptor.decode(descriptor.encoded()) == descriptor
      )
      #expect(descriptor.expectedFingerprints.count == 2)
    }
  }

  @Test
  func rejectsOversizeInput() {
    let padded = String(repeating: " ", count: 2049)
    #expect(throws: HostConnectionDescriptor.DecodingError.tooLarge) {
      try HostConnectionDescriptor.decode(padded)
    }
  }

  @Test
  func rejectsOtherKindsAndVersions() {
    var root = object()
    root["kind"] = "swiftty-session"
    #expect(throws: HostConnectionDescriptor.DecodingError.unsupportedKind) {
      try HostConnectionDescriptor.decode(json(root))
    }
    for version: Any in [2, 0, "1", true, 1.5] {
      root = object()
      root["version"] = version
      #expect(throws: HostConnectionDescriptor.DecodingError.unsupportedVersion)
      { try HostConnectionDescriptor.decode(json(root)) }
    }
  }

  @Test
  func rejectsUnknownFields() {
    for extra in [["token": "x"], ["command": "rm -rf ~"], ["workspace": "x"]] {
      #expect(throws: HostConnectionDescriptor.DecodingError.self) {
        try HostConnectionDescriptor.decode(json(object(extra: extra)))
      }
    }
    #expect(throws: HostConnectionDescriptor.DecodingError.self) {
      try HostConnectionDescriptor.decode(
        json(object(sshExtra: ["password": "hunter2"]))
      )
    }
    #expect(throws: HostConnectionDescriptor.DecodingError.self) {
      try HostConnectionDescriptor.decode(
        json(
          object(keys: [
            ["algorithm": "ssh-ed25519", "sha256": Self.zeroPrint, "key": "x"]
          ])
        )
      )
    }
  }

  @Test(arguments: [
    "", "-oProxyCommand=sh", "ssh://macbook.local", "mac book.local",
    "macbook.local.", "user@macbook", "macbook.local:22", "fe80::1%en0",
    "[fd00::1]", "a..b", "-mac", "mac-", "10.0.0.256", "1234", "mac;reboot",
    "mäc.local", String(repeating: "a", count: 64) + ".local",
  ])
  func rejectsInvalidHosts(_ host: String) {
    #expect(throws: HostConnectionDescriptor.DecodingError.self) {
      try HostConnectionDescriptor.decode(json(object(host: host)))
    }
  }

  @Test
  func rejectsInvalidPorts() {
    let ports: [Any] = [0, 65_536, -1, "22", 22.5, true]
    for port in ports {
      #expect(throws: HostConnectionDescriptor.DecodingError.invalidPort) {
        try HostConnectionDescriptor.decode(json(object(port: port)))
      }
    }
  }

  @Test(arguments: ["", "-l", "root;id", "a b", "$(id)", ".hidden"])
  func rejectsInvalidUsernames(_ username: String) {
    #expect(throws: HostConnectionDescriptor.DecodingError.invalidUsername) {
      try HostConnectionDescriptor.decode(json(object(username: username)))
    }
  }

  @Test(
    arguments: [
      "My\u{7}Mac", "Mac\nBook", "https://evil.example", "Mac`id`", "Mac$(id)",
      " Mac", "Mac\u{202E}", String(repeating: "M", count: 65),
    ]
    .map(TestFixture.init)
  )
  func rejectsInjectedNames(_ fixture: TestFixture<String>) {
    let name = fixture.value
    #expect(throws: HostConnectionDescriptor.DecodingError.invalidName) {
      try HostConnectionDescriptor.decode(json(object(name: name)))
    }
  }

  @Test
  func rejectsInvalidFingerprints() {
    let bad: [Any] = [
      [],
      Array(
        repeating: ["algorithm": "ssh-ed25519", "sha256": Self.zeroPrint],
        count: 2
      ), [["algorithm": "ssh-ed25519", "sha256": "SHA256:short"]],
      [
        [
          "algorithm": "ssh-ed25519",
          "sha256": "MD5:" + String(repeating: "A", count: 43),
        ]
      ], [["algorithm": "ssh-ed25519", "sha256": Self.zeroPrint + "="]],
      [["algorithm": "ssh-rsa", "sha256": Self.zeroPrint]],
      [["algorithm": "ssh-ed25519"]], ["SHA256:x"],
      (0 ..< 5)
        .map { i in
          [
            "algorithm": "ssh-ed25519",
            "sha256": "SHA256:"
              + Data(repeating: UInt8(i), count: 32).base64EncodedString()
              .replacingOccurrences(of: "=", with: ""),
          ]
        },
    ]
    for keys in bad {
      #expect(throws: HostConnectionDescriptor.DecodingError.invalidHostKeys) {
        try HostConnectionDescriptor.decode(json(object(keys: keys)))
      }
    }
  }

  @Test
  func rejectsMalformedInput() {
    for text in ["", "null", "[]", "{", "\"swiftty-host\"", "{\"kind\":1}"] {
      #expect(throws: HostConnectionDescriptor.DecodingError.self) {
        try HostConnectionDescriptor.decode(text)
      }
    }
    #expect(throws: HostConnectionDescriptor.DecodingError.malformed) {
      try HostConnectionDescriptor.decode(Data([0xFF, 0xFE, 0x7B]))
    }
  }

  @Test
  func encoderRefusesInvalidDescriptors() {
    var descriptor = Self.sample
    descriptor.hostKeys = []
    #expect(throws: HostConnectionDescriptor.EncodingError.self) {
      try descriptor.encoded()
    }
  }
}

struct HostDiscoveryTests {
  @Test
  func advertisedTXTIsBoundedAndCarriesNoIdentity() {
    let bytes = HostDiscovery.txtRecord(HostDiscovery.advertisedTXT)
    #expect(bytes.count <= HostDiscovery.maxTXTBytes)
    #expect(Set(HostDiscovery.advertisedTXT.keys) == ["txtvers", "product"])
    #expect(
      HostDiscovery.validate(
        txt: HostDiscovery.advertisedTXT,
        byteCount: bytes.count
      ) == .accepted
    )
  }

  @Test
  func rejectsUnsupportedOrOversizeTXT() {
    #expect(HostDiscovery.validate(txt: [:], byteCount: 0) == .unsupported)
    #expect(
      HostDiscovery.validate(
        txt: ["product": "swiftty", "txtvers": "2"],
        byteCount: 20
      ) == .unsupported
    )
    #expect(
      HostDiscovery.validate(txt: HostDiscovery.advertisedTXT, byteCount: 513)
        == .tooLarge
    )
  }

  @Test
  func sanitizesInstanceNames() {
    #expect(
      HostDiscovery.sanitizedName("  Chris's\u{0}\nMac\u{202E}  ")
        == "Chris's Mac"
    )
    let long = HostDiscovery.sanitizedName(String(repeating: "é", count: 64))
    #expect(long.utf8.count <= HostDiscovery.maxInstanceNameBytes)
    #expect(HostDiscovery.sanitizedName("\u{1}\u{2}") == "")
  }
}
