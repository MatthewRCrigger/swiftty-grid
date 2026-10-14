import Crypto
import Foundation
import SessionCore
@testable import SSHClient
import Testing
import TestSupport

@Suite(.serialized, .timeLimit(.minutes(1)))
struct SFTPRemoteHashTests {
  private func data(size: Int) -> Data {
    Data((0 ..< size).map { UInt8(truncatingIfNeeded: $0 ^ ($0 / 17)) })
  }

  @Test(arguments: [1, 4], [0, 1, 8195])
  func remoteHashPreservesOffsetsAcrossSuspendedReads(
    outstanding: Int,
    size: Int
  ) async throws {
    let fixture = try await TransferFixture.make()
    var connection: SSHConnection?
    try await RuntimeFixture.withCleanup {
      let bytes = data(size: size)
      try fixture.remoteFile("/source.bin", data: bytes)
      let (owner, client) = try await fixture.session()
      connection = owner
      let digest = try await SFTPTransfers.remoteSHA256(
        client: client,
        path: "/source.bin",
        length: UInt64(size),
        options: SFTPTransferOptions(
          chunkSize: 1024,
          maxOutstanding: outstanding
        ),
        gate: OpenTransferGate(),
        expectEOF: true
      )
      #expect(digest == hexString(SHA256.hash(data: bytes)))
      #expect(
        fixture.server.state.reads.withLock { $0 } == (size + 1023) / 1024 + 1
      )
    } cleanup: {
      await connection?.close()
      await fixture.cleanup()
    }
  }

  @Test(arguments: [0, 1024, 8192])
  func positionedReadReturnsTheRequestedBytes(_ offset: Int) async throws {
    let fixture = try await TransferFixture.make()
    var connection: SSHConnection?
    try await RuntimeFixture.withCleanup {
      let bytes = data(size: 8195)
      try fixture.remoteFile("/source.bin", data: bytes)
      let (owner, client) = try await fixture.session()
      connection = owner
      let handle = try await client.open("/source.bin", flags: [.read])
      let read = try await client.read(
        handle,
        offset: UInt64(offset),
        length: 3
      )
      #expect(read == Array(bytes[offset ..< offset + 3]))
      try await client.close(handle)
    } cleanup: {
      await connection?.close()
      await fixture.cleanup()
    }
  }
}
