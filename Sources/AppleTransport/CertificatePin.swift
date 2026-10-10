import Crypto
import Foundation
import SessionCore
import X509

public enum CertificatePinError: Error, Equatable, Sendable {
  /// The fingerprint is not 64 hexadecimal digits.
  case malformedFingerprint
  /// The pinned DER does not hash to the pinned fingerprint.
  case inconsistentPin
  /// The peer presented no certificate.
  case missingCertificate
  /// The peer's leaf hashes to a different fingerprint.
  case fingerprintMismatch
  /// The peer's leaf DER differs from the pinned DER.
  case certificateMismatch
  /// The pinned DER is not a parseable X.509 certificate.
  case malformedCertificate
  case notYetValid
  case expired
}

/// The exact server certificate delivered through the SSH-authenticated
/// bootstrap (spec §5.2). It is a connection-scoped trust anchor: the QUIC
/// client accepts exactly this leaf and nothing else — no system trust, no
/// other self-signed certificate, no chain building.
public struct CertificatePin: Hashable, Sendable {
  public let certificateDER: Data
  /// Lowercase hex SHA-256 of `certificateDER`.
  public let sha256: String

  /// Pins `certificateDER`, computing its fingerprint.
  public init(certificateDER: Data) {
    self.certificateDER = certificateDER
    self.sha256 = Self.fingerprint(certificateDER)
  }

  /// Pins a bootstrap pair. Fails when the two disagree, so a grant whose
  /// DER and fingerprint do not match is never trusted.
  public init(
    certificateDER: Data,
    sha256: String
  ) throws(CertificatePinError) {
    guard bytes(fromHex: sha256, count: SHA256.byteCount) != nil else {
      throw .malformedFingerprint
    }
    let actual = Self.fingerprint(certificateDER)
    guard actual == sha256.lowercased() else { throw .inconsistentPin }
    self.certificateDER = certificateDER
    self.sha256 = actual
  }

  /// Lowercase hex SHA-256 of `der`.
  public static func fingerprint(_ der: Data) -> String {
    hexString(SHA256.hash(data: der))
  }

  /// Validates a presented leaf against the pin: equal fingerprint, equal
  /// DER, and `now` within the certificate's validity window. Pure; the
  /// TLS verify block calls this and fails closed on any error.
  public func validate(
    leafDER: Data?,
    now: Date = Date()
  ) throws(CertificatePinError) {
    guard let leafDER, !leafDER.isEmpty else { throw .missingCertificate }
    guard Self.fingerprint(leafDER) == sha256 else {
      throw .fingerprintMismatch
    }
    guard leafDER == certificateDER else { throw .certificateMismatch }
    let certificate: Certificate
    do {
      certificate = try Certificate(derEncoded: Array(leafDER))
    } catch {
      throw .malformedCertificate
    }
    guard now >= certificate.notValidBefore else { throw .notYetValid }
    guard now <= certificate.notValidAfter else { throw .expired }
  }
}
