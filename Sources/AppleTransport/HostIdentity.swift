#if os(macOS)
  import Crypto
  import Foundation
  import Security
  import SessionCore
  import X509

  public enum HostIdentityError: Error, Equatable, Sendable {
    case invalidValidity
    case certificateEncoding
    case keyImport(Int32)
    case certificateImport
    case identityCreation
    case storage(String)
    case insecureStorage(String)
  }

  /// The `swifttyd` QUIC/TLS server identity (spec §5.2, §14 Gate 0).
  ///
  /// The key is a fresh P-256 key owned by the helper and independent of
  /// the SSH host key. The certificate is self-issued with swift-certificates
  /// and trusted by clients only because its exact DER and SHA-256 travel
  /// inside the SSH-authenticated bootstrap grant (`CertificatePin`).
  ///
  /// ## Certificate/Keychain integration spike: the chosen approach
  ///
  /// Network framework needs a `sec_identity_t`, i.e. a `SecIdentity`
  /// pairing the certificate with its private key. Candidates on macOS 27:
  ///
  /// - `SecPKCS12Import` with `kSecImportToMemoryOnly` keeps the identity
  ///   out of the keychain, but needs a password-protected PKCS #12 blob
  ///   that swift-certificates cannot produce; hand-rolling PKCS #12 PBE
  ///   and MAC structures is needless crypto surface.
  /// - A private file keychain plus `SecIdentityCreateWithCertificate`
  ///   relies on the deprecated `SecKeychain` API family.
  /// - The data-protection keychain requires a keychain-access-group
  ///   entitlement that an unsigned/ad-hoc command-line helper and the
  ///   test runner do not have (`errSecMissingEntitlement`).
  /// - **Chosen:** `SecIdentityCreate(_:_:_:)`, public in the OS 27 SDKs,
  ///   combines an in-memory `SecCertificate` with an in-memory `SecKey`
  ///   created by `SecKeyCreateWithData`. Nothing touches the keychain, so
  ///   the helper works as a plain per-user launchd agent.
  ///
  /// Persistence is a pair of files in an owner-only directory (0700),
  /// each written 0600 atomically: `host-key.raw` (the 32-byte P-256
  /// scalar) and `host-cert.der`. Ownership and permissions are verified
  /// on load; a group/other-accessible file is refused rather than used.
  /// The certificate is replaced when it nears expiry or its subject
  /// alternative names change; replacement implies clients receive the new
  /// pin through fresh SSH authentication.
  public struct HostIdentity: @unchecked Sendable {
    // SecIdentity is an immutable, thread-safe CF object.
    public let certificateDER: Data
    /// Lowercase hex SHA-256 of `certificateDER` for the bootstrap grant.
    public let certificateSHA256: String
    public let notValidBefore: Date
    public let notValidAfter: Date
    public let secIdentity: SecIdentity

    /// Default certificate lifetime.
    public static let defaultValidity: TimeInterval = 30 * 24 * 3600
    /// Regenerate when less than this remains.
    public static let renewalMargin: TimeInterval = 3 * 24 * 3600
    static let backdate: TimeInterval = 5 * 60
    static let keyFile = "host-key.raw"
    static let certificateFile = "host-cert.der"

    /// The pin a client would use for this identity.
    public var pin: CertificatePin { CertificatePin(certificateDER: certificateDER) }

    /// The Network framework representation.
    public var protocolIdentity: sec_identity_t? { sec_identity_create(secIdentity) }

    /// Generates a fresh in-memory identity.
    ///
    /// - Parameters:
    ///   - hostnames: DNS names for the subject alternative names. Clients
    ///     pin the exact DER, so names are descriptive, not trust inputs.
    ///   - ipAddresses: Textual IPv4/IPv6 addresses for IP SANs.
    public static func generate(
      hostnames: [String] = [],
      ipAddresses: [String] = [],
      validity: TimeInterval = defaultValidity,
      now: Date = Date()
    ) throws -> HostIdentity {
      let key = P256.Signing.PrivateKey()
      let der = try makeCertificate(
        key: key, hostnames: hostnames, ipAddresses: ipAddresses,
        validity: validity, now: now
      )
      return try HostIdentity(key: key, certificateDER: der)
    }

    /// Loads the persisted identity from `directory`, generating and
    /// storing a new one when absent, unreadable, near expiry, or issued
    /// for different names.
    public static func loadOrCreate(
      directory: URL,
      hostnames: [String] = [],
      ipAddresses: [String] = [],
      validity: TimeInterval = defaultValidity,
      now: Date = Date()
    ) throws -> HostIdentity {
      try prepareDirectory(directory)
      if let existing = try? load(directory: directory),
        existing.notValidBefore <= now,
        existing.notValidAfter.timeIntervalSince(now) > renewalMargin,
        existing.matches(hostnames: hostnames, ipAddresses: ipAddresses)
      {
        return existing
      }
      let key = P256.Signing.PrivateKey()
      let der = try makeCertificate(
        key: key, hostnames: hostnames, ipAddresses: ipAddresses,
        validity: validity, now: now
      )
      let identity = try HostIdentity(key: key, certificateDER: der)
      try writeOwnerOnly(
        key.rawRepresentation, to: directory.appending(path: keyFile)
      )
      try writeOwnerOnly(der, to: directory.appending(path: certificateFile))
      return identity
    }

    /// Loads a persisted identity, verifying owner-only permissions.
    public static func load(directory: URL) throws -> HostIdentity {
      try checkOwnerOnly(directory, mode: 0o700)
      let keyURL = directory.appending(path: keyFile)
      let certURL = directory.appending(path: certificateFile)
      try checkOwnerOnly(keyURL, mode: 0o600)
      try checkOwnerOnly(certURL, mode: 0o600)
      do {
        let key = try P256.Signing.PrivateKey(
          rawRepresentation: try Data(contentsOf: keyURL)
        )
        return try HostIdentity(
          key: key, certificateDER: try Data(contentsOf: certURL)
        )
      } catch let error as HostIdentityError {
        throw error
      } catch {
        throw HostIdentityError.storage("unreadable identity")
      }
    }

    init(key: P256.Signing.PrivateKey, certificateDER: Data) throws {
      let certificate: Certificate
      do {
        certificate = try Certificate(derEncoded: Array(certificateDER))
      } catch {
        throw HostIdentityError.certificateEncoding
      }
      // The certificate must certify this key.
      guard
        certificate.publicKey == Certificate.PublicKey(key.publicKey)
      else { throw HostIdentityError.identityCreation }

      let attributes: [CFString: Any] = [
        kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
        kSecAttrKeyClass: kSecAttrKeyClassPrivate,
        kSecAttrKeySizeInBits: 256,
      ]
      var error: Unmanaged<CFError>?
      // SecKey's external private-key format is 04 || X || Y || D.
      guard
        let secKey = SecKeyCreateWithData(
          key.x963Representation as CFData,
          attributes as CFDictionary, &error
        )
      else {
        let code = error.map { CFErrorGetCode($0.takeRetainedValue()) } ?? 0
        throw HostIdentityError.keyImport(Int32(truncatingIfNeeded: code))
      }
      guard
        let secCertificate = SecCertificateCreateWithData(
          nil, certificateDER as CFData
        )
      else { throw HostIdentityError.certificateImport }
      guard
        let identity = SecIdentityCreate(nil, secCertificate, secKey)
      else { throw HostIdentityError.identityCreation }

      self.certificateDER = certificateDER
      self.certificateSHA256 = CertificatePin.fingerprint(certificateDER)
      self.notValidBefore = certificate.notValidBefore
      self.notValidAfter = certificate.notValidAfter
      self.secIdentity = identity
    }

    func matches(hostnames: [String], ipAddresses: [String]) -> Bool {
      guard
        let certificate = try? Certificate(derEncoded: Array(certificateDER)),
        let expected = try? Self.subjectAlternativeNames(
          hostnames: hostnames, ipAddresses: ipAddresses
        )
      else { return false }
      let actual =
        (try? certificate.extensions.subjectAlternativeNames)
        ?? nil
      return Set(actual.map(Array.init) ?? []) == Set(expected)
    }

    // MARK: Certificate construction

    static func subjectAlternativeNames(
      hostnames: [String],
      ipAddresses: [String]
    ) throws -> [GeneralName] {
      var names = hostnames.map { GeneralName.dnsName($0) }
      for text in ipAddresses {
        guard let bytes = ipBytes(text) else {
          throw HostIdentityError.certificateEncoding
        }
        names.append(.ipAddress(.init(contentBytes: ArraySlice(bytes))))
      }
      return names
    }

    static func makeCertificate(
      key: P256.Signing.PrivateKey,
      hostnames: [String],
      ipAddresses: [String],
      validity: TimeInterval,
      now: Date
    ) throws -> Data {
      guard validity > 0, validity <= 397 * 24 * 3600 else {
        throw HostIdentityError.invalidValidity
      }
      let names = try subjectAlternativeNames(
        hostnames: hostnames, ipAddresses: ipAddresses
      )
      let subject = try DistinguishedName {
        CommonName("swifttyd")
        OrganizationName("swiftty RST/1")
      }
      var serial = secureRandomBytes(20)
      serial[0] &= 0x7F  // Positive, at most 20 octets (RFC 5280 §4.1.2.2).
      if serial[0] == 0 { serial[0] = 1 }
      let extensions = try Certificate.Extensions {
        Critical(BasicConstraints.notCertificateAuthority)
        Critical(KeyUsage(digitalSignature: true))
        try ExtendedKeyUsage([.serverAuth])
        SubjectKeyIdentifier(hash: Certificate.PublicKey(key.publicKey))
        if !names.isEmpty { SubjectAlternativeNames(names) }
      }
      let certificate = try Certificate(
        version: .v3,
        serialNumber: Certificate.SerialNumber(bytes: ArraySlice(serial)),
        publicKey: Certificate.PublicKey(key.publicKey),
        notValidBefore: now.addingTimeInterval(-backdate),
        notValidAfter: now.addingTimeInterval(validity),
        issuer: subject,
        subject: subject,
        signatureAlgorithm: .ecdsaWithSHA256,
        extensions: extensions,
        issuerPrivateKey: Certificate.PrivateKey(key)
      )
      do {
        return Data(try certificate.serializeAsPEM().derBytes)
      } catch {
        throw HostIdentityError.certificateEncoding
      }
    }

    static func ipBytes(_ text: String) -> [UInt8]? {
      var v4 = in_addr()
      if inet_pton(AF_INET, text, &v4) == 1 {
        return withUnsafeBytes(of: v4) { Array($0) }
      }
      var v6 = in6_addr()
      if inet_pton(AF_INET6, text, &v6) == 1 {
        return withUnsafeBytes(of: v6) { Array($0) }
      }
      return nil
    }

    // MARK: Owner-only storage

    static func prepareDirectory(_ directory: URL) throws {
      let path = directory.path(percentEncoded: false)
      var isDirectory: ObjCBool = false
      if !FileManager.default.fileExists(
        atPath: path, isDirectory: &isDirectory
      ) {
        guard mkdir(path, 0o700) == 0 || errno == EEXIST else {
          throw HostIdentityError.storage("mkdir errno \(errno)")
        }
      } else if !isDirectory.boolValue {
        throw HostIdentityError.storage("not a directory")
      }
      try checkOwnerOnly(directory, mode: 0o700)
    }

    /// Requires the path to be owned by this user, not a symlink, and to
    /// grant nothing to group/other.
    static func checkOwnerOnly(_ url: URL, mode: mode_t) throws {
      var info = stat()
      let path = url.path(percentEncoded: false)
      guard lstat(path, &info) == 0 else {
        throw HostIdentityError.storage("missing \(url.lastPathComponent)")
      }
      guard (info.st_mode & S_IFMT) != S_IFLNK, info.st_uid == getuid()
      else { throw HostIdentityError.insecureStorage(url.lastPathComponent) }
      guard info.st_mode & 0o077 == 0 else {
        throw HostIdentityError.insecureStorage(url.lastPathComponent)
      }
    }

    /// Writes via a 0600 temporary file in the same directory and renames
    /// it into place, so a reader never sees a partial or wider file.
    static func writeOwnerOnly(_ data: Data, to url: URL) throws {
      let directory = url.deletingLastPathComponent()
      let temporary = directory.appending(
        path: ".\(url.lastPathComponent).\(hexString(secureRandomBytes(6)))"
      )
      let path = temporary.path(percentEncoded: false)
      let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
      guard fd >= 0 else {
        throw HostIdentityError.storage("open errno \(errno)")
      }
      var ok = fchmod(fd, 0o600) == 0
      data.withUnsafeBytes { buffer in
        var offset = 0
        while ok, offset < buffer.count {
          let n = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
          if n > 0 {
            offset += n
          } else if n < 0, errno == EINTR {
            continue
          } else {
            ok = false
          }
        }
      }
      ok = ok && fsync(fd) == 0
      close(fd)
      guard ok, rename(path, url.path(percentEncoded: false)) == 0 else {
        unlink(path)
        throw HostIdentityError.storage("write failed")
      }
    }
  }
#endif
