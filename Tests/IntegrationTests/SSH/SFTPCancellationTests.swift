import Foundation
import NIOCore
import SessionCore
import Synchronization
import Testing

@testable import SSHClient

@Suite(.serialized, .timeLimit(.minutes(1)))
struct SFTPCancellationTests {
  @Test(arguments: [false, true])
  func injectedDisconnectClosesEverySubsystem(_ rename: Bool) async throws {
    let fixture = try await TransferFixture.make()
    defer { Task { await fixture.cleanup() } }
    try fixture.remoteFile("/source.bin", data: Data([1, 2, 3]))
    let connection = try await fixture.server.connect()
    defer { Task { await connection.close() } }
    let first = try await connection.openSFTP(requestTimeout: .seconds(1))
    let second = try await connection.openSFTP(requestTimeout: .seconds(1))
    let handle = try await first.open("/source.bin", flags: [.read])
    fixture.server.state.faults.withLock { $0.holdNextReadResponse = true }
    let reading = Task { try await first.read(handle, offset: 0, length: 3) }
    do {
      #expect(
        try await waitUntil {
          fixture.server.state.heldSFTPResponse.withLock { $0 != nil }
        }
      )
      let count = fixture.server.state.sftpRequests.withLock { $0 }
      fixture.server.state.faults.withLock {
        if rename {
          $0.dropRenameResponse = true
        } else {
          $0.dropAfterRequests = count
        }
      }
      await #expect(throws: SFTPError.connectionClosed) {
        if rename {
          try await second.rename("/source.bin", to: "/renamed.bin")
        } else {
          _ = try await second.realpath("/")
        }
      }
      await #expect(throws: SFTPError.connectionClosed) {
        _ = try await reading.value
      }
      #expect(
        try await waitUntil {
          fixture.server.state.lastSFTPDrop.withLock {
            $0?.parentClosed == true && $0?.childClosed == true
          } && !connection.isActive && !first.isActive && !second.isActive
        }
      )
      let observation = try #require(
        fixture.server.state.lastSFTPDrop.withLock { $0 }
      )
      #expect(observation.parentPresent)
      #expect(observation.cause == (rename ? .rename : .requestLimit))
      #expect(observation.requestID > 0)
      #expect(observation.operation == (rename ? .rename : .realpath))
      #expect(
        fixture.remoteData(rename ? "/renamed.bin" : "/source.bin")
          == Data([1, 2, 3])
      )
      let (fresh, client) = try await fixture.session()
      defer { Task { await fresh.close() } }
      #expect(try await client.realpath("/") == "/")
      await fresh.close()
    } catch {
      await connection.close()
      _ = try? await reading.value
      await fixture.cleanup()
      throw error
    }
    await fixture.cleanup()
  }

  @Test
  func closingOneSubsystemPreservesOtherHandles() async throws {
    let fixture = try await TransferFixture.make()
    defer { Task { await fixture.cleanup() } }
    try fixture.remoteFile("/source.bin", data: Data([1, 2, 3]))
    let (connection, first) = try await fixture.session()
    defer { Task { await connection.close() } }
    let second = try await connection.openSFTP()
    _ = try await first.open("/source.bin", flags: [.read])
    let handle = try await second.open("/source.bin", flags: [.read])
    #expect(fixture.server.state.sftpOpenHandles.withLock { $0 } == 2)
    await first.close()
    #expect(
      try await waitUntil {
        fixture.server.state.sftpOpenHandles.withLock { $0 } == 1
      }
    )
    #expect(try await second.read(handle, offset: 0, length: 3) == [1, 2, 3])
    await second.close()
    #expect(
      try await waitUntil {
        fixture.server.state.sftpOpenHandles.withLock { $0 } == 0
      }
    )
    await connection.close()
    await fixture.cleanup()
  }

  @Test(arguments: [false, true])
  func disconnectReleasesHandlesWithHeldResponses(_ holdAll: Bool) async throws
  {
    let fixture = try await TransferFixture.make()
    defer { Task { await fixture.cleanup() } }
    try fixture.remoteFile("/source.bin", data: Data([1, 2, 3]))
    let (connection, client) = try await fixture.session()
    defer { Task { await connection.close() } }
    let handle = try await client.open("/source.bin", flags: [.read])
    fixture.server.state.faults.withLock {
      $0.holdAllReadResponses = holdAll
      $0.holdNextReadResponse = !holdAll
    }
    let reading = Task { try await client.read(handle, offset: 0, length: 3) }
    do {
      #expect(
        try await waitUntil {
          holdAll
            ? fixture.server.state.heldSFTPResponses.withLock { !$0.isEmpty }
            : fixture.server.state.heldSFTPResponse.withLock { $0 != nil }
        }
      )
      let releases =
        holdAll
        ? fixture.server.state.heldSFTPResponses.withLock { $0 }
        : fixture.server.state.heldSFTPResponse.withLock {
          $0.map { [$0] } ?? []
        }
      await connection.close()
      await #expect(throws: SFTPError.connectionClosed) {
        _ = try await reading.value
      }
      #expect(
        try await waitUntil(timeout: .seconds(1)) {
          fixture.server.state.sftpOpenHandles.withLock { $0 } == 0
        }
      )
      await fixture.server.shutdown()
      #expect(fixture.server.state.heldSFTPResponse.withLock { $0 == nil })
      #expect(fixture.server.state.heldSFTPResponses.withLock { $0.isEmpty })
      // A caller may already have taken the callback before disconnection.
      for release in releases { release() }
    } catch {
      await connection.close()
      _ = try? await reading.value
      await fixture.cleanup()
      throw error
    }
    await fixture.cleanup()
  }

  @Test
  func cancellingTheVersionHandshakeKeepsSSHUsable() async throws {
    let fixture = try await TransferFixture.make()
    defer { Task { await fixture.cleanup() } }
    let connection = try await fixture.server.connect()
    defer { Task { await connection.close() } }
    fixture.server.state.faults.withLock { $0.withholdVersionResponse = true }
    let task = Task {
      try await connection.openSFTP(requestTimeout: .milliseconds(500))
    }
    #expect(
      try await waitUntil {
        fixture.server.state.sftpInitializations.withLock { $0 } == 1
      }
    )
    task.cancel()
    await #expect(throws: CancellationError.self) { _ = try await task.value }
    fixture.server.state.faults.withLock { $0.withholdVersionResponse = false }
    let client = try await connection.openSFTP()
    #expect(client.isActive)
    await client.close()
  }

  @Test
  func rejectedChannelSetupFailsReadinessOnce() async throws {
    let fixture = try await TransferFixture.make()
    defer { Task { await fixture.cleanup() } }
    let connection = try await fixture.server.connect()
    defer { Task { await connection.close() } }
    fixture.server.state.faults.withLock { $0.rejectSessionChannel = true }
    await #expect(throws: SSHClientError.channelRequestRejected("session")) {
      _ = try await connection.openSFTP()
    }
    fixture.server.state.faults.withLock { $0.rejectSessionChannel = false }
    let client = try await connection.openSFTP()
    #expect(client.isActive)
    await client.close()
  }

  @Test(arguments: ["request", "upload", "download", "verify"])
  func cancellationCompletesBeforeTheStalledResponse(
    pipeline: String
  ) async throws {
    let fixture = try await TransferFixture.make()
    defer { Task { await fixture.cleanup() } }
    let (source, data) = try fixture.sourceFile(size: 32 * 1024)
    try fixture.remoteFile("/source.bin", data: data)
    let (connection, client) = try await fixture.session()
    defer { Task { await connection.close() } }
    let handle = try await client.open("/source.bin", flags: [.read])
    let upload = try await SFTPTransfers.prepareUpload(
      source: source,
      remotePath: "/upload.bin",
      stagingDirectory: fixture.staging
    )
    let download = try SFTPTransfers.prepareDownload(
      remotePath: "/source.bin",
      temporaryDirectory: fixture.local,
      destination: fixture.local.appendingPathComponent("download.bin")
    )
    let finished = Mutex(false)
    fixture.server.state.faults.withLock {
      $0.holdNextReadResponse = pipeline != "upload"
      $0.holdNextWriteResponse = pipeline == "upload"
    }
    let transfer = Task {
      defer { finished.withLock { $0 = true } }
      let options = SFTPTransferOptions(chunkSize: 1024, maxOutstanding: 4)
      do {
        switch pipeline {
        case "request":
          _ = try await client.read(handle, offset: 0, length: 1024)
        case "upload":
          var manifest = upload
          try await SFTPTransfers.upload(
            &manifest,
            client: client,
            options: options
          )
        case "download":
          var manifest = download
          try await SFTPTransfers.download(
            &manifest,
            client: client,
            options: options
          )
        default:
          _ = try await SFTPTransfers.remoteSHA256(
            client: client,
            path: "/source.bin",
            length: UInt64(data.count),
            options: options,
            gate: OpenTransferGate(),
            expectEOF: true
          )
        }
        return false
      } catch is CancellationError { return true }
    }
    #expect(
      try await waitUntil {
        fixture.server.state.heldSFTPResponse.withLock { $0 != nil }
      }
    )
    transfer.cancel()
    let completedBeforeRelease = try await waitUntil(timeout: .seconds(1)) {
      finished.withLock { $0 }
    }
    #expect(completedBeforeRelease)
    // An unrelated request must still work while the cancelled response is held.
    #expect(
      try await client.read(handle, offset: 1024, length: 1024)
        == Array(data[1024 ..< 2048])
    )
    let release = fixture.server.state.heldSFTPResponse.withLock { pending in
      defer { pending = nil }
      return pending
    }
    release?()
    #expect(try await transfer.value)
    // A late reply to the cancelled request must not close the subsystem.
    #expect(try await client.stat("/source.bin").size == UInt64(data.count))
    #expect(
      try await waitUntil {
        fixture.server.state.sftpOpenHandles.withLock { $0 } == 1
      }
    )
    try await client.close(handle)
  }

  @Test
  func preCancelledRequestDoesNotReachTheServer() async throws {
    let fixture = try await TransferFixture.make()
    defer { Task { await fixture.cleanup() } }
    let (connection, client) = try await fixture.session()
    defer { Task { await connection.close() } }
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      await #expect(throws: CancellationError.self) {
        _ = try await client.stat("/missing")
      }
    }
    await task.value
    #expect(fixture.server.state.sftpRequests.withLock { $0 } == 0)
  }

  @Test
  func cancelledOpenClosesItsLateRemoteHandle() async throws {
    let fixture = try await TransferFixture.make()
    defer { Task { await fixture.cleanup() } }
    try fixture.remoteFile("/source.bin", data: Data([1]))
    let (connection, client) = try await fixture.session()
    defer { Task { await connection.close() } }
    fixture.server.state.faults.withLock { $0.holdNextOpenResponse = true }
    let task = Task { try await client.open("/source.bin", flags: [.read]) }
    #expect(
      try await waitUntil {
        fixture.server.state.heldSFTPResponse.withLock { $0 != nil }
      }
    )
    #expect(fixture.server.state.sftpOpenHandles.withLock { $0 } == 1)
    task.cancel()
    await #expect(throws: CancellationError.self) { _ = try await task.value }
    fixture.server.state.heldSFTPResponse.withLock { pending in
      pending?()
      pending = nil
    }
    #expect(
      try await waitUntil {
        fixture.server.state.sftpOpenHandles.withLock { $0 } == 0
      }
    )
    #expect(client.isActive)
  }

  @Test
  func queuedCancellationDoesNotSendTheRequest() async throws {
    let fixture = try await TransferFixture.make()
    defer { Task { await fixture.cleanup() } }
    try fixture.remoteFile(
      "/source.bin",
      data: Data(repeating: 1, count: 16 * 1024)
    )
    let (connection, client) = try await fixture.session()
    defer { Task { await connection.close() } }
    let handle = try await client.open("/source.bin", flags: [.read])
    fixture.server.state.faults.withLock { $0.holdAllReadResponses = true }
    let tasks = (0 ..< RSTLimits.sftpOutstandingRequests)
      .map { index in
        Task {
          try await client.read(
            handle,
            offset: UInt64(index * 1024),
            length: 1024
          )
        }
      }
    #expect(
      try await waitUntil {
        fixture.server.state.heldSFTPResponses.withLock {
          $0.count == RSTLimits.sftpOutstandingRequests
        }
      }
    )
    let cancellation = SFTPRequestCancellation()
    let future = try await client.channel.eventLoop
      .submit {
        let handler = try client.channel.pipeline.syncOperations.handler(
          type: SFTPChannelHandler.self
        )
        return handler.enqueue(
          .read(id: 0, handle: handle.bytes, offset: 8192, length: 1024),
          cancellation: cancellation
        )
      }
      .get()
    try await client.channel.eventLoop
      .submit {
        cancellation.cancelled.withLock { $0 = true }
        let handler = try client.channel.pipeline.syncOperations.handler(
          type: SFTPChannelHandler.self
        )
        handler.cancel(cancellation)
      }
      .get()
    await #expect(throws: CancellationError.self) { _ = try await future.get() }
    fixture.server.state.faults.withLock { $0.holdAllReadResponses = false }
    fixture.server.state.heldSFTPResponses.withLock { pending in
      for release in pending { release() }
      pending = []
    }
    for task in tasks { _ = try await task.value }
    try await client.close(handle)
    #expect(
      fixture.server.state.reads.withLock { $0 }
        == RSTLimits.sftpOutstandingRequests
    )
  }

  @Test(arguments: [false, true])
  func unansweredRequestOrHandshakeTimesOut(handshake: Bool) async throws {
    let fixture = try await TransferFixture.make()
    defer { Task { await fixture.cleanup() } }
    try fixture.remoteFile("/source.bin", data: Data([1]))
    let connection = try await fixture.server.connect()
    defer { Task { await connection.close() } }
    if handshake {
      fixture.server.state.faults.withLock { $0.withholdVersionResponse = true }
      await #expect(throws: SFTPError.requestTimedOut) {
        _ = try await connection.openSFTP(requestTimeout: .milliseconds(200))
      }
    } else {
      let client = try await connection.openSFTP(
        requestTimeout: .milliseconds(200)
      )
      let handle = try await client.open("/source.bin", flags: [.read])
      fixture.server.state.faults.withLock { $0.holdNextReadResponse = true }
      await #expect(throws: SFTPError.requestTimedOut) {
        _ = try await client.read(handle, offset: 0, length: 1)
      }
      #expect(try await waitUntil { !client.isActive })
      // Release the fixture's retained callback after the client closes.
      fixture.server.state.heldSFTPResponse.withLock { $0 = nil }
    }
    // Only the SFTP subsystem closed; the SSH connection still works.
    fixture.server.state.faults.withLock { $0.withholdVersionResponse = false }
    let replacement = try await connection.openSFTP()
    #expect(replacement.isActive)
    await replacement.close()
  }

  @Test
  func cancelledWireRequestsKeepTheirSlotsUntilTimeout() async throws {
    let fixture = try await TransferFixture.make()
    defer { Task { await fixture.cleanup() } }
    try fixture.remoteFile(
      "/source.bin",
      data: Data(repeating: 1, count: 16 * 1024)
    )
    let connection = try await fixture.server.connect()
    defer { Task { await connection.close() } }
    let client = try await connection.openSFTP(requestTimeout: .seconds(2))
    let handle = try await client.open("/source.bin", flags: [.read])
    fixture.server.state.faults.withLock { $0.holdAllReadResponses = true }
    let tasks = (0 ..< RSTLimits.sftpOutstandingRequests)
      .map { index in
        Task {
          try await client.read(
            handle,
            offset: UInt64(index * 1024),
            length: 1024
          )
        }
      }
    #expect(
      try await waitUntil {
        fixture.server.state.heldSFTPResponses.withLock {
          $0.count == RSTLimits.sftpOutstandingRequests
        }
      }
    )
    for task in tasks { task.cancel() }
    for task in tasks {
      await #expect(throws: CancellationError.self) { _ = try await task.value }
    }
    let queued = Task {
      try await client.read(handle, offset: 8192, length: 1024)
    }
    try await Task.sleep(for: .milliseconds(50))
    #expect(
      fixture.server.state.reads.withLock { $0 }
        == RSTLimits.sftpOutstandingRequests
    )
    await #expect(throws: SFTPError.requestTimedOut) {
      _ = try await queued.value
    }
    #expect(try await waitUntil { !client.isActive })
    fixture.server.state.heldSFTPResponses.withLock { $0 = [] }
  }
}
