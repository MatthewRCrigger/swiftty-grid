import Foundation
import NIOCore
import NIOSSH
import SessionCore

public enum SFTPError: Error, Equatable, Sendable {
  /// The server answered with a non-OK status.
  case status(SFTPStatus)
  case protocolError(SFTPCodecError)
  case unexpectedResponse
  case unsupportedVersion(UInt32)
  /// More than the bounded number of requests are waiting.
  case queueFull
  case connectionClosed
  case invalidPath
  case invalidLength
  case subsystemRejected

  public var statusCode: SFTPStatusCode? {
    if case let .status(status) = self { status.code } else { nil }
  }
}

/// Opaque server handle; valid only on the subsystem that issued it.
public struct SFTPFileHandle: Hashable, Sendable {
  public let bytes: [UInt8]
}

/// SFTP v3 client over one `sftp` subsystem channel (spec §10). At most
/// `RSTLimits.sftpOutstandingRequests` requests are on the wire; up to
/// `maxQueuedRequests` more wait in a bounded queue.
///
/// Reconnecting requires a new client: handles never survive a channel.
public final class SFTPClient: Sendable {
  public static let maxQueuedRequests = 32
  /// Largest single read/write payload accepted by this client.
  public static let maxIOLength = 64 * 1024

  let channel: any Channel
  /// Extensions advertised in the server's `VERSION` packet.
  public let serverExtensions: [SFTPExtensionPair]

  init(channel: any Channel, serverExtensions: [SFTPExtensionPair]) {
    self.channel = channel
    self.serverExtensions = serverExtensions
  }

  public var supportsPOSIXRename: Bool {
    serverExtensions.contains { $0.name == "posix-rename@openssh.com" }
  }

  public var isActive: Bool { channel.isActive }

  /// Closes the subsystem channel; outstanding requests fail. Idempotent.
  public func close() async {
    channel.close(promise: nil)
    try? await channel.closeFuture.get()
  }

  // MARK: Operations

  public func realpath(_ path: String) async throws -> String {
    try validate(path)
    let response = try await send(.realpath(id: 0, path: path))
    guard case let .name(_, entries) = response, entries.count == 1 else {
      throw SFTPError.unexpectedResponse
    }
    return entries[0].filename
  }

  public func stat(_ path: String) async throws -> SFTPAttributes {
    try validate(path)
    return try attributes(await send(.stat(id: 0, path: path)))
  }

  public func lstat(_ path: String) async throws -> SFTPAttributes {
    try validate(path)
    return try attributes(await send(.lstat(id: 0, path: path)))
  }

  public func fstat(_ handle: SFTPFileHandle) async throws -> SFTPAttributes {
    try attributes(await send(.fstat(id: 0, handle: handle.bytes)))
  }

  public func open(
    _ path: String,
    flags: SFTPOpenFlags,
    attributes: SFTPAttributes = SFTPAttributes()
  ) async throws -> SFTPFileHandle {
    try validate(path)
    return try handle(
      await send(.open(id: 0, path: path, flags: flags, attributes))
    )
  }

  public func openDirectory(_ path: String) async throws -> SFTPFileHandle {
    try validate(path)
    return try handle(await send(.opendir(id: 0, path: path)))
  }

  /// The next batch of entries, or `nil` at end of directory.
  public func readDirectory(
    _ handle: SFTPFileHandle
  ) async throws -> [SFTPNameEntry]? {
    switch try await send(.readdir(id: 0, handle: handle.bytes), allowEOF: true)
    {
    case let .name(_, entries): return entries
    case .status(_, let status) where status.code == .eof: return nil
    default: throw SFTPError.unexpectedResponse
    }
  }

  /// Lists a directory, excluding `.` and `..`, bounded by `maxEntries`.
  public func listDirectory(
    _ path: String,
    maxEntries: Int = 10_000
  ) async throws -> [SFTPNameEntry] {
    let handle = try await openDirectory(path)
    var entries: [SFTPNameEntry] = []
    do {
      while let batch = try await readDirectory(handle) {
        for entry in batch where entry.filename != "." && entry.filename != ".."
        {
          guard entries.count < maxEntries else {
            throw SFTPError.status(
              SFTPStatus(code: .failure, message: "too many entries")
            )
          }
          entries.append(entry)
        }
      }
    } catch {
      try? await close(handle)
      throw error
    }
    try await close(handle)
    return entries
  }

  /// Closes a handle; a non-OK status is thrown so callers can treat
  /// failed closes as failed writes.
  public func close(_ handle: SFTPFileHandle) async throws {
    try expectOK(await send(.close(id: 0, handle: handle.bytes)))
  }

  /// Reads up to `length` bytes at `offset`; `nil` at end of file. May
  /// return fewer bytes than requested.
  public func read(
    _ handle: SFTPFileHandle,
    offset: UInt64,
    length: Int
  ) async throws -> [UInt8]? {
    guard (1 ... Self.maxIOLength).contains(length) else {
      throw SFTPError.invalidLength
    }
    let response = try await send(
      .read(
        id: 0,
        handle: handle.bytes,
        offset: offset,
        length: UInt32(length)
      ),
      allowEOF: true
    )
    switch response {
    case let .data(_, data):
      guard data.count <= length else { throw SFTPError.unexpectedResponse }
      return data
    case .status(_, let status) where status.code == .eof: return nil
    default: throw SFTPError.unexpectedResponse
    }
  }

  /// Positioned write; never uses append mode.
  public func write(
    _ handle: SFTPFileHandle,
    offset: UInt64,
    data: [UInt8]
  ) async throws {
    guard data.count <= Self.maxIOLength else { throw SFTPError.invalidLength }
    try expectOK(
      await send(
        .write(id: 0, handle: handle.bytes, offset: offset, data: data)
      )
    )
  }

  /// SFTP v3 rename; fails if `newPath` exists on OpenSSH servers.
  public func rename(_ oldPath: String, to newPath: String) async throws {
    try validate(oldPath)
    try validate(newPath)
    try expectOK(
      await send(.rename(id: 0, oldPath: oldPath, newPath: newPath))
    )
  }

  /// `posix-rename@openssh.com`: atomically replaces `newPath`.
  public func posixRename(_ oldPath: String, to newPath: String) async throws {
    try validate(oldPath)
    try validate(newPath)
    var w = SFTPWriter()
    w.string(oldPath)
    w.string(newPath)
    try expectOK(
      await send(
        .extended(id: 0, name: "posix-rename@openssh.com", data: w.bytes)
      )
    )
  }

  public func remove(_ path: String) async throws {
    try validate(path)
    try expectOK(await send(.remove(id: 0, path: path)))
  }

  // MARK: Plumbing

  private func validate(_ path: String) throws {
    guard !path.isEmpty, path.utf8.count <= SFTPLimits.maxPathBytes,
      !path.utf8.contains(0)
    else { throw SFTPError.invalidPath }
  }

  private func attributes(_ message: SFTPMessage) throws -> SFTPAttributes {
    guard case let .attrs(_, attributes) = message else {
      throw SFTPError.unexpectedResponse
    }
    return attributes
  }

  private func handle(_ message: SFTPMessage) throws -> SFTPFileHandle {
    guard case let .handle(_, bytes) = message else {
      throw SFTPError.unexpectedResponse
    }
    return SFTPFileHandle(bytes: bytes)
  }

  private func expectOK(_ message: SFTPMessage) throws {
    guard case .status = message else { throw SFTPError.unexpectedResponse }
  }

  /// Sends `request` (its id is assigned by the handler) and returns the
  /// response. Non-OK statuses throw, except EOF when `allowEOF`.
  private func send(
    _ request: SFTPMessage,
    allowEOF: Bool = false
  ) async throws -> SFTPMessage {
    let channel = self.channel
    let response = try await channel.eventLoop.flatSubmit {
      () -> EventLoopFuture<SFTPMessage> in
      guard
        let handler = try? channel.pipeline.syncOperations.handler(
          type: SFTPChannelHandler.self
        )
      else {
        return channel.eventLoop.makeFailedFuture(SFTPError.connectionClosed)
      }
      return handler.enqueue(request)
    }.get()
    if case let .status(_, status) = response, status.code != .ok {
      if allowEOF, status.code == .eof { return response }
      throw SFTPError.status(status)
    }
    return response
  }
}

/// Subsystem handler: framing, request ids, the outstanding window and
/// the bounded wait queue. Runs on the channel's event loop.
final class SFTPChannelHandler: ChannelInboundHandler {
  typealias InboundIn = SSHChannelData

  private enum Phase { case requestingSubsystem, awaitingVersion, ready, closed }

  private let ready: EventLoopPromise<[SFTPExtensionPair]>
  private let maxOutstanding: Int
  private var phase = Phase.requestingSubsystem
  private var reader = SFTPPacketReader()
  private var nextID: UInt32 = 1
  private var outstanding: [UInt32: EventLoopPromise<SFTPMessage>] = [:]
  private var queue = CircularBuffer<(SFTPMessage, EventLoopPromise<SFTPMessage>)>()
  private var context: ChannelHandlerContext?
  private var readyCompleted = false

  init(
    ready: EventLoopPromise<[SFTPExtensionPair]>,
    maxOutstanding: Int = RSTLimits.sftpOutstandingRequests
  ) {
    self.ready = ready
    self.maxOutstanding = maxOutstanding
  }

  func handlerAdded(context: ChannelHandlerContext) {
    self.context = context
  }

  func handlerRemoved(context: ChannelHandlerContext) {
    self.context = nil
  }

  func channelActive(context: ChannelHandlerContext) {
    context.triggerUserOutboundEvent(
      SSHChannelRequestEvent.SubsystemRequest(subsystem: "sftp", wantReply: true),
      promise: nil
    )
    context.fireChannelActive()
  }

  func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
    switch event {
    case is ChannelSuccessEvent where phase == .requestingSubsystem:
      phase = .awaitingVersion
      transmit(.initialize(version: 3, extensions: []), context: context)
    case is ChannelFailureEvent where phase == .requestingSubsystem:
      fail(SFTPError.subsystemRejected, context: context)
    default:
      context.fireUserInboundEventTriggered(event)
    }
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    let message = unwrapInboundIn(data)
    guard phase != .closed, case .channel = message.type,
      case let .byteBuffer(buffer) = message.data
    else { return }
    reader.append(buffer.readableBytesView)
    do {
      while let packet = try reader.next() {
        try handle(packet, context: context)
        if phase == .closed { return }
      }
    } catch let error as SFTPCodecError {
      fail(SFTPError.protocolError(error), context: context)
    } catch {
      fail(error, context: context)
    }
  }

  func errorCaught(context: ChannelHandlerContext, error: any Error) {
    fail(SFTPError.connectionClosed, context: context)
  }

  func channelInactive(context: ChannelHandlerContext) {
    failAll(SFTPError.connectionClosed)
    phase = .closed
    context.fireChannelInactive()
  }

  /// Queues or transmits a request, assigning its id.
  func enqueue(_ request: SFTPMessage) -> EventLoopFuture<SFTPMessage> {
    let promise = ready.futureResult.eventLoop.makePromise(
      of: SFTPMessage.self
    )
    guard let context, phase == .ready else {
      promise.fail(SFTPError.connectionClosed)
      return promise.futureResult
    }
    if outstanding.count < maxOutstanding {
      send(request, promise: promise, context: context)
    } else if queue.count < SFTPClient.maxQueuedRequests {
      queue.append((request, promise))
    } else {
      promise.fail(SFTPError.queueFull)
    }
    return promise.futureResult
  }

  private func send(
    _ request: SFTPMessage,
    promise: EventLoopPromise<SFTPMessage>,
    context: ChannelHandlerContext
  ) {
    var id = nextID
    while outstanding[id] != nil { id &+= 1 }
    nextID = id &+ 1
    outstanding[id] = promise
    transmit(request.replacingID(id), context: context)
  }

  private func transmit(_ message: SFTPMessage, context: ChannelHandlerContext)
  {
    let bytes = message.encoded()
    var buffer = context.channel.allocator.buffer(capacity: bytes.count)
    buffer.writeBytes(bytes)
    context.writeAndFlush(
      NIOAny(SSHChannelData(type: .channel, data: .byteBuffer(buffer))),
      promise: nil
    )
  }

  private func handle(
    _ packet: SFTPMessage,
    context: ChannelHandlerContext
  ) throws {
    switch (phase, packet) {
    case let (.awaitingVersion, .version(version, extensions)):
      guard version == 3 else {
        throw SFTPError.unsupportedVersion(version)
      }
      phase = .ready
      readyCompleted = true
      ready.succeed(extensions)
    case (.ready, .status), (.ready, .handle), (.ready, .data),
      (.ready, .name), (.ready, .attrs):
      guard let id = packet.id, let promise = outstanding.removeValue(
        forKey: id
      ) else { throw SFTPError.unexpectedResponse }
      promise.succeed(packet)
      if let (request, next) = queue.popFirst() {
        send(request, promise: next, context: context)
      }
    default:
      throw SFTPError.unexpectedResponse
    }
  }

  private func fail(_ error: any Error, context: ChannelHandlerContext) {
    failAll(error)
    phase = .closed
    context.close(promise: nil)
  }

  private func failAll(_ error: any Error) {
    if !readyCompleted {
      readyCompleted = true
      ready.fail(error)
    }
    let pending = outstanding.values
    outstanding.removeAll()
    for promise in pending { promise.fail(error) }
    while let (_, promise) = queue.popFirst() { promise.fail(error) }
  }
}

extension SFTPMessage {
  /// The same request with request id `id`.
  func replacingID(_ id: UInt32) -> SFTPMessage {
    switch self {
    case .initialize, .version: self
    case let .open(_, path, flags, attrs):
      .open(id: id, path: path, flags: flags, attrs)
    case let .close(_, handle): .close(id: id, handle: handle)
    case let .read(_, handle, offset, length):
      .read(id: id, handle: handle, offset: offset, length: length)
    case let .write(_, handle, offset, data):
      .write(id: id, handle: handle, offset: offset, data: data)
    case let .lstat(_, path): .lstat(id: id, path: path)
    case let .fstat(_, handle): .fstat(id: id, handle: handle)
    case let .opendir(_, path): .opendir(id: id, path: path)
    case let .readdir(_, handle): .readdir(id: id, handle: handle)
    case let .remove(_, path): .remove(id: id, path: path)
    case let .realpath(_, path): .realpath(id: id, path: path)
    case let .stat(_, path): .stat(id: id, path: path)
    case let .rename(_, old, new): .rename(id: id, oldPath: old, newPath: new)
    case let .extended(_, name, data): .extended(id: id, name: name, data: data)
    case let .status(_, status): .status(id: id, status)
    case let .handle(_, handle): .handle(id: id, handle)
    case let .data(_, data): .data(id: id, data)
    case let .name(_, entries): .name(id: id, entries)
    case let .attrs(_, attrs): .attrs(id: id, attrs)
    }
  }
}

extension SSHConnection {
  /// Opens a new `sftp` subsystem channel and completes the v3
  /// `INIT`/`VERSION` exchange.
  public func openSFTP() async throws -> SFTPClient {
    let ready = channel.eventLoop.makePromise(of: [SFTPExtensionPair].self)
    let child: any Channel
    do {
      child = try await openSessionChannel { child in
        try child.pipeline.syncOperations.addHandler(
          SFTPChannelHandler(ready: ready)
        )
      }
    } catch {
      ready.fail(error)
      throw error
    }
    let extensions = try await ready.futureResult.get()
    return SFTPClient(channel: child, serverExtensions: extensions)
  }
}
