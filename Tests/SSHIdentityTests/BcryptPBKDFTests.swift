import Testing

@testable import SSHIdentity

/// Known-answer tests for the local `bcrypt_pbkdf` (spec.ssh-identity.md
/// §6.4). End-to-end interoperability is covered by the ssh-keygen fixtures
/// in `OpenSSHKeyImporterTests`.
@Suite
struct BcryptPBKDFTests {
  static func hex(_ s: String) -> [UInt8] {
    var bytes: [UInt8] = []
    var index = s.startIndex
    while index < s.endIndex {
      let next = s.index(index, offsetBy: 2)
      bytes.append(UInt8(s[index ..< next], radix: 16)!)
      index = next
    }
    return bytes
  }

  /// Eric Young's Blowfish ECB vectors: (key, plaintext, ciphertext).
  @Test(arguments: [
    ("0000000000000000", "0000000000000000", "4EF997456198DD78"),
    ("FFFFFFFFFFFFFFFF", "FFFFFFFFFFFFFFFF", "51866FD5B85ECB8A"),
    ("3000000000000000", "1000000000000001", "7D856F9A613063F2"),
    ("FEDCBA9876543210", "0123456789ABCDEF", "0ACEAB0FC6A0A28D"),
  ])
  func blowfishMatchesReferenceVectors(_ vector: (String, String, String)) {
    func words(_ hex: String) -> [UInt32] {
      let b = Self.hex(hex)
      return [0, 4]
        .map { i in b[i ..< i + 4].reduce(0) { $0 << 8 | UInt32($1) } }
    }
    var cipher = Blowfish(key: Self.hex(vector.0))
    var block = words(vector.1)
    cipher.encrypt(&block)
    #expect(block == words(vector.2))
  }

  @Test
  func rejectsInvalidParameters() {
    for (pass, salt, rounds, length) in [
      ([UInt8](), [UInt8(1)], 1, 32), ([1], [], 1, 32), ([1], [1], 0, 32),
      ([1], [1], 1, 0), ([1], [1], 1, 32 * 32 + 1),
    ] {
      #expect(throws: BcryptPBKDF.Failure.invalidParameters) {
        try BcryptPBKDF.derive(
          passphrase: pass,
          salt: salt,
          rounds: rounds,
          length: length
        )
      }
    }
  }

  @Test
  func outputDependsOnEveryInput() throws {
    func derive(_ pass: String, _ salt: String, _ rounds: Int) throws -> [UInt8]
    {
      try BcryptPBKDF.derive(
        passphrase: Array(pass.utf8),
        salt: Array(salt.utf8),
        rounds: rounds,
        length: 48
      )
    }
    let base = try derive("password", "salt", 2)
    #expect(base.count == 48)
    #expect(try derive("password", "salt", 2) == base)
    #expect(try derive("passwore", "salt", 2) != base)
    #expect(try derive("password", "salu", 2) != base)
    #expect(try derive("password", "salt", 3) != base)
  }
}
