import Foundation
import TestSupport
import Testing

@testable import SSHClient

@Suite(.timeLimit(.minutes(1)))
struct SFTPBoundsTests {
  @Test(arguments: 0 ..< 10)
  func encoderAppliesTheSameFieldCapsAsDecoder(_ field: Int) {
    let message: SFTPMessage
    let error: SFTPCodecError
    switch field {
    case 0, 1:
      let pairs = Array(
        repeating: SFTPExtensionPair(name: "x", data: []),
        count: 65
      )
      message =
        field == 0
        ? .initialize(version: 3, extensions: pairs)
        : .version(version: 3, extensions: pairs)
      error = .tooManyEntries
    case 2:
      message = .open(
        id: 1,
        path: String(repeating: "é", count: 2049),
        flags: .read,
        .init()
      )
      error = .stringTooLong
    case 3:
      message = .handle(id: 1, Array(repeating: 0, count: 257))
      error = .stringTooLong
    case 4:
      let entry = SFTPNameEntry(filename: "", longname: "", attributes: .init())
      message = .name(id: 1, Array(repeating: entry, count: 1025))
      error = .tooManyEntries
    case 5:
      message = .name(
        id: 1,
        [
          .init(
            filename: "x",
            longname: String(repeating: "x", count: 8193),
            attributes: .init()
          )
        ]
      )
      error = .stringTooLong
    case 6:
      message = .status(
        id: 1,
        .init(code: .failure, message: String(repeating: "x", count: 4097))
      )
      error = .stringTooLong
    case 7:
      message = .status(
        id: 1,
        .init(code: .failure, language: String(repeating: "x", count: 257))
      )
      error = .stringTooLong
    case 8:
      message = .extended(
        id: 1,
        name: String(repeating: "x", count: 4097),
        data: []
      )
      error = .stringTooLong
    default:
      message = .attrs(
        id: 1,
        .init(extended: [
          .init(name: String(repeating: "x", count: 4097), data: [])
        ])
      )
      error = .stringTooLong
    }
    #expect(throws: error) { try message.encoded() }
  }

  @Test(arguments: [false, true])
  func nonprogressDirectoryResponsesFailAndCloseHandle(
    _ dots: Bool
  ) async throws {
    let fixture = try await TransferFixture.make()
    defer { Task { await fixture.cleanup() } }
    let entry = SFTPNameEntry(filename: ".", longname: "", attributes: .init())
    fixture.server.state.faults.withLock {
      $0.readDirectoryBatches = Array(repeating: dots ? [entry] : [], count: 6)
    }
    let (connection, client) = try await fixture.session()
    defer { Task { await connection.close() } }
    await #expect(throws: SFTPError.unexpectedResponse) {
      try await client.listDirectory("/", maxEntries: 0)
    }
    #expect(
      fixture.server.state.directoryReads.withLock { $0 } == (dots ? 3 : 1)
    )
    #expect(fixture.server.state.sftpOpenHandles.withLock { $0 } == 0)
    #expect(client.isActive)
    _ = try await client.stat("/")
    await connection.close()
    await fixture.cleanup()
  }

  @Test
  func dotEntriesDoNotConsumeTheVisibleLimitAndExactBoundarySucceeds()
    async throws
  {
    let fixture = try await TransferFixture.make()
    defer { Task { await fixture.cleanup() } }
    try fixture.remoteFile("/visible", data: Data([1]))
    let dot = SFTPNameEntry(filename: ".", longname: "", attributes: .init())
    let parent = SFTPNameEntry(
      filename: "..",
      longname: "",
      attributes: .init()
    )
    fixture.server.state.faults.withLock {
      $0.readDirectoryBatches = [[dot], [parent]]
    }
    let (connection, client) = try await fixture.session()
    defer { Task { await connection.close() } }
    let entries = try await client.listDirectory("/", maxEntries: 1)
    #expect(entries.map(\.filename) == ["visible"])
    #expect(fixture.server.state.directoryReads.withLock { $0 } == 4)
    #expect(fixture.server.state.sftpOpenHandles.withLock { $0 } == 0)
    await #expect(
      throws: SFTPError.status(
        .init(code: .failure, message: "too many entries")
      )
    ) { try await client.listDirectory("/", maxEntries: 0) }
    #expect(fixture.server.state.sftpOpenHandles.withLock { $0 } == 0)
    let requests = fixture.server.state.sftpRequests.withLock { $0 }
    await #expect(throws: SFTPError.invalidLength) {
      try await client.listDirectory("/", maxEntries: -1)
    }
    #expect(fixture.server.state.sftpRequests.withLock { $0 } == requests)
    await connection.close()
    await fixture.cleanup()
  }

  @Test(arguments: 0 ..< 7)
  func invalidOpenAttributesNeverReachWireOrOccupyRequestWindow(
    _ invalid: Int
  ) async throws {
    let fixture = try await TransferFixture.make()
    defer { Task { await fixture.cleanup() } }
    let (connection, client) = try await fixture.session()
    defer { Task { await connection.close() } }
    var attributes = SFTPAttributes()
    let error: SFTPCodecError
    switch invalid {
    case 0:
      attributes.extended = Array(
        repeating: .init(name: "x", data: []),
        count: 65
      )
      error = .tooManyEntries
    case 1:
      attributes.extended = [
        .init(name: "x", data: Array(repeating: 1, count: 4097))
      ]
      error = .stringTooLong
    case 2:
      attributes.uid = 501
      error = .invalidAttributes
    case 3:
      attributes.modificationTime = 1
      error = .invalidAttributes
    case 4:
      attributes.extended = Array(
        repeating: .init(
          name: String(repeating: "x", count: 4096),
          data: Array(repeating: 1, count: 4096)
        ),
        count: 64
      )
      let firstOversizedBody = 29 + 32 * (8 + 2 * SFTPLimits.maxExtensionBytes)
      error = .packetTooLarge(firstOversizedBody)
    case 5:
      attributes.gid = 20
      error = .invalidAttributes
    default:
      attributes.accessTime = 1
      error = .invalidAttributes
    }
    // Repeat beyond both request-window capacities: invalid local requests
    // must never consume a slot or leave work waiting for a response.
    for _ in 0 ..< 48 {
      await #expect(throws: SFTPError.protocolError(error)) {
        try await client.open(
          "/invalid",
          flags: [.write, .create],
          attributes: attributes
        )
      }
    }
    #expect(fixture.server.state.sftpRequests.withLock { $0 } == 0)
    #expect(fixture.server.state.sftpOpenHandles.withLock { $0 } == 0)
    #expect(client.isActive)
    let handle = try await client.open(
      "/valid",
      flags: [.write, .create],
      attributes: .init(permissions: 0o600)
    )
    try await client.close(handle)
    #expect(fixture.server.state.sftpRequests.withLock { $0 } == 2)
    await connection.close()
    await fixture.cleanup()
  }

  @Test
  func codecRejectsOversizedPacketBeforeReadingPayloadElements() throws {
    var writer = SFTPWriter(collectBytes: true)
    try writer.byte(1)
    let input = ReadCountingBytes(prefix: [], count: Int.max)
    #expect(throws: SFTPCodecError.packetTooLarge(.max)) {
      try writer.raw(input)
    }
    #expect(input.elementReads == 0)
    #expect(writer.bytes == [1])
    var countOnly = SFTPWriter(collectBytes: false)
    try countOnly.string([1, 2, 3], max: 3)
    #expect(countOnly.bodyLength == 7)
    #expect(countOnly.bytes.isEmpty)
  }

  @Test
  func codecMatchesExactPacketBoundaryAndCountsAllAttributeBytes() throws {
    let headerBytes = 9
    let exact = SFTPMessage.data(
      id: 1,
      Array(repeating: 1, count: SFTPLimits.maxPacketBytes - headerBytes)
    )
    let bytes = try exact.encoded()
    #expect(bytes.count == SFTPLimits.maxPacketBytes + 4)
    #expect(try exact.validatedBodyLength() == SFTPLimits.maxPacketBytes)
    #expect(try SFTPMessage.decode(body: bytes.dropFirst(4)) == exact)
    let oversized = SFTPMessage.data(
      id: 1,
      Array(repeating: 1, count: SFTPLimits.maxPacketBytes - headerBytes + 1)
    )
    #expect(
      throws: SFTPCodecError.packetTooLarge(SFTPLimits.maxPacketBytes + 1)
    ) { try oversized.encoded() }
    let extended = Array(
      repeating: SFTPExtensionPair(
        name: String(repeating: "x", count: 4096),
        data: Array(repeating: 1, count: 4096)
      ),
      count: 64
    )
    let attributes = SFTPMessage.attrs(id: 1, .init(extended: extended))
    let firstOversizedBody = 13 + 32 * (8 + 2 * SFTPLimits.maxExtensionBytes)
    #expect(throws: SFTPCodecError.packetTooLarge(firstOversizedBody)) {
      try attributes.encoded()
    }
    let one = SFTPMessage.attrs(
      id: 1,
      .init(extended: Array(extended.prefix(1)))
    )
    let encoded = try one.encoded()
    #expect(try SFTPMessage.decode(body: encoded.dropFirst(4)) == one)
    let pairs = Array(
      repeating: SFTPExtensionPair(name: "x", data: [1]),
      count: 64
    )
    let complete = SFTPMessage.open(
      id: 1,
      path: String(repeating: "é", count: 2048),
      flags: .read,
      .init(
        size: .max,
        uid: .max,
        gid: .max,
        permissions: 0o600,
        accessTime: .max,
        modificationTime: .max,
        extended: pairs
      )
    )
    let packet = try complete.encoded()
    #expect(try SFTPMessage.decode(body: packet.dropFirst(4)) == complete)
  }
}
