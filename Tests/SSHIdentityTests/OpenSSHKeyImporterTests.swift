import Crypto
import Foundation
import SSHClient
import Testing

@testable import SSHIdentity

/// KEY-05: bounded unencrypted `openssh-key-v1` import
/// (spec.ssh-identity.md §6.2).
@Suite
struct OpenSSHKeyImporterTests {
  static func fixture(_ name: String) throws -> Data {
    let url = try #require(
      Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
    )
    return try Data(contentsOf: url)
  }

  static func expectedFingerprint(_ name: String) throws -> String {
    let line = String(decoding: try fixture("\(name).pub"), as: UTF8.self)
    return try #require(SSHPublicKeyFormat.fingerprint(openSSHPublicKey: line))
  }

  static func decode(
    _ data: Data
  ) -> Result<ImportedOpenSSHKey, OpenSSHImportError> {
    Result { () throws(OpenSSHImportError) in
      try OpenSSHKeyImporter.decode(data)
    }
  }

  static func failure(_ data: Data) -> OpenSSHImportError? {
    if case .failure(let error) = decode(data) { return error }
    return nil
  }

  @Test
  func importsAnUnencryptedKey() throws {
    let key = try Self.decode(try Self.fixture("plain")).get()
    #expect(key.fingerprint == (try Self.expectedFingerprint("plain")))
    #expect(key.comment == "plain@fixture")
    #expect(key.inspection.algorithm == "ssh-ed25519")
  }

  /// Encrypted OpenSSH keys are refused explicitly: v1 adds no bcrypt
  /// compatibility (spec.ssh-identity.md §6.2).
  @Test
  func refusesEncryptedKeys() throws {
    #expect(
      Self.failure(try Self.fixture("aes256")) == .encryptedKeyUnsupported
    )
    var b = Builder()
    b.cipher = "aes256-ctr"
    b.kdf = "bcrypt"
    b.kdfOptions = Builder.string([1, 2, 3, 4]) + Builder.uint32(16)
    #expect(Self.failure(b.data()) == .encryptedKeyUnsupported)
    b = Builder()
    b.kdf = "bcrypt"
    #expect(Self.failure(b.data()) == .encryptedKeyUnsupported)
    b = Builder()
    b.cipher = "chacha20-poly1305@openssh.com"
    #expect(Self.failure(b.data()) == .encryptedKeyUnsupported)
  }

  @Test
  func refusesUnsupportedInputs() throws {
    #expect(
      Self.failure(try Self.fixture("rsa")) == .unsupportedAlgorithm("ssh-rsa")
    )
    #expect(
      Self.failure(try Self.fixture("ecdsa-pem"))
        == .unsupportedFormat("PEM EC")
    )
    #expect(Self.failure(try Self.fixture("plain.pub")) == .publicKeyOnly)
    #expect(Self.failure(try Self.fixture("plain-cert.pub")) == .certificate)
    #expect(Self.failure(Data("hello".utf8)) == .unrecognizedFormat)
    #expect(Self.failure(Data([0xFF, 0xFE])) == .unrecognizedFormat)
    let huge = Data(
      repeating: 0x41,
      count: OpenSSHKeyImporter.maxInputBytes + 1
    )
    #expect(Self.failure(huge) == .inputTooLarge)
  }

  // MARK: Synthetic containers

  /// Builds `openssh-key-v1` containers so each validation rule can be
  /// exercised on its own.
  struct Builder {
    var cipher = "none"
    var kdf = "none"
    var kdfOptions: [UInt8] = []
    var count: UInt32 = 1
    var key = Curve25519.Signing.PrivateKey()
    var publicKey: Curve25519.Signing.PublicKey?
    var check: (UInt32, UInt32) = (7, 7)
    var comment = Array("synthetic".utf8)
    var padding: [UInt8]?
    var trailing: [UInt8] = []
    var privateTail: [UInt8]?
    var blockSize = 8

    static func string(_ bytes: [UInt8]) -> [UInt8] {
      let n = UInt32(bytes.count)
      return [
        UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF),
        UInt8(n & 0xFF),
      ] + bytes
    }

    static func uint32(_ n: UInt32) -> [UInt8] {
      [
        UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF),
        UInt8(n & 0xFF),
      ]
    }

    func publicBlob(_ key: Curve25519.Signing.PublicKey) -> [UInt8] {
      Self.string(Array("ssh-ed25519".utf8))
        + Self.string(Array(key.rawRepresentation))
    }

    func section() -> [UInt8] {
      var body = Self.uint32(check.0) + Self.uint32(check.1)
      body += Self.string(Array("ssh-ed25519".utf8))
      body += Self.string(Array(key.publicKey.rawRepresentation))
      body += Self.string(
        privateTail
          ?? (Array(key.rawRepresentation)
            + Array(key.publicKey.rawRepresentation))
      )
      body += Self.string(comment)
      if let padding {
        body += padding
      } else {
        var i: UInt8 = 1
        while body.count % blockSize != 0 {
          body.append(i)
          i += 1
        }
      }
      return body
    }

    func data() -> Data {
      var bytes = Array("openssh-key-v1".utf8) + [0]
      bytes += Self.string(Array(cipher.utf8))
      bytes += Self.string(Array(kdf.utf8))
      bytes += Self.string(kdfOptions)
      bytes += Self.uint32(count)
      bytes += Self.string(publicBlob(publicKey ?? key.publicKey))
      bytes += Self.string(section())
      bytes += trailing
      let body = Data(bytes)
        .base64EncodedString(options: [
          .lineLength64Characters, .endLineWithLineFeed,
        ])
      return Data(
        "\(OpenSSHKeyImporter.beginArmor)\n\(body)\n\(OpenSSHKeyImporter.endArmor)\n"
          .utf8
      )
    }
  }

  @Test
  func syntheticBaselineImports() throws {
    let builder = Builder()
    let key = try Self.decode(builder.data()).get()
    #expect(
      key.secret.publicKey.rawRepresentation
        == builder.key.publicKey.rawRepresentation
    )
    #expect(key.comment == "synthetic")
  }

  @Test
  func validatesStructure() {
    var b = Builder()
    b.check = (1, 2)
    #expect(Self.failure(b.data()) == .malformed)

    b = Builder()
    b.padding = [1, 3]
    #expect(Self.failure(b.data()) == .invalidPadding)

    b = Builder()
    b.trailing = [0]
    #expect(Self.failure(b.data()) == .malformed)

    b = Builder()
    b.count = 2
    #expect(Self.failure(b.data()) == .unsupportedKeyCount(2))
    b.count = 0
    #expect(Self.failure(b.data()) == .malformed)

    b = Builder()
    b.publicKey = Curve25519.Signing.PrivateKey().publicKey
    #expect(Self.failure(b.data()) == .keyMismatch)

    b = Builder()
    b.privateTail =
      Array(b.key.rawRepresentation)
      + Array(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
    #expect(Self.failure(b.data()) == .keyMismatch)

    b = Builder()
    b.comment = Array(repeating: 0x61, count: 1025)
    #expect(Self.failure(b.data()) == .commentTooLarge)
  }

  @Test
  func noneKDFMustHaveEmptyOptions() {
    var b = Builder()
    b.kdfOptions = [0]
    #expect(Self.failure(b.data()) == .malformed)
  }

  @Test
  func oversizedLengthsFailBeforeAllocation() {
    var bytes = Array("openssh-key-v1".utf8) + [0]
    bytes += [0x7F, 0xFF, 0xFF, 0xFF]
    let text =
      "\(OpenSSHKeyImporter.beginArmor)\n\(Data(bytes).base64EncodedString())\n"
      + "\(OpenSSHKeyImporter.endArmor)\n"
    #expect(Self.failure(Data(text.utf8)) == .malformed)
  }

  @Test
  func cancelledImportDiscardsItsResult() async throws {
    let data = try Self.fixture("plain")
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await OpenSSHImportGate().decode(data)
    }
    await #expect(throws: OpenSSHImportError.cancelled) { try await task.value }
  }
}
