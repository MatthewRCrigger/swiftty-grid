import Darwin
import Foundation
import NIOCore
import NIOSSH
import Testing

@testable import SSHClient

/// Minimal SFTP v3 server backed by a temporary directory, implementing
/// the client's subset with fault injection. Runs on the channel's
/// event loop with small synchronous file operations (test only).
final class TestSFTPServer {
  enum OpenItem {
    case file(Int32)
    case directory([SFTPNameEntry])
  }

  let root: String
  let state: TestServerState
  var reader = SFTPPacketReader()
  var items: [UInt32: OpenItem] = [:]
  var nextHandle: UInt32 = 1

  init(root: String, state: TestServerState) {
    self.root = root
    self.state = state
  }

  deinit { closeHandles() }

  func closeHandles() {
    let count = items.count
    for case let .file(fd) in items.values { close(fd) }
    items.removeAll()
    state.sftpOpenHandles.withLock { $0 -= count }
  }

  private struct ResponseTarget {
    weak var server: TestSFTPServer?
    weak var context: ChannelHandlerContext?
  }

  func receive(_ bytes: [UInt8], context: ChannelHandlerContext) {
    reader.append(bytes)
    do {
      while let message = try reader.next() {
        guard context.channel.isActive else { return }
        handle(message, context: context)
      }
    } catch { context.close(promise: nil) }
  }

  private func respond(_ message: SFTPMessage, context: ChannelHandlerContext) {
    guard context.channel.isActive else { return }
    let bytes: [UInt8]
    do { bytes = try message.encoded() } catch {
      Issue.record(error)
      context.close(promise: nil)
      return
    }
    var buffer = context.channel.allocator.buffer(capacity: bytes.count)
    buffer.writeBytes(bytes)
    context.writeAndFlush(
      NIOAny(SSHChannelData(type: .channel, data: .byteBuffer(buffer))),
      promise: nil
    )
  }

  private func dropConnection(
    _ context: ChannelHandlerContext,
    requestID: UInt32,
    message: SFTPMessage,
    cause: TestServerState.SFTPDrop.Cause
  ) {
    let operation: TestServerState.SFTPDrop.Operation
    switch message {
    case .open: operation = .open
    case .close: operation = .close
    case .read: operation = .read
    case .write: operation = .write
    case .fstat: operation = .fstat
    case .stat: operation = .stat
    case .rename: operation = .rename
    case .realpath: operation = .realpath
    default: operation = .other
    }
    let parent = context.channel.parent
    let observation = TestServerState.SFTPDrop(
      operation: operation,
      cause: cause,
      requestID: requestID,
      parentPresent: parent != nil
    )
    let state = state
    state.lastSFTPDrop.withLock { $0 = observation }
    context.channel.closeFuture.whenComplete { _ in
      state.lastSFTPDrop.withLock {
        if $0?.id == observation.id { $0?.childClosed = true }
      }
    }
    parent?.closeFuture
      .whenComplete { _ in
        state.lastSFTPDrop.withLock {
          if $0?.id == observation.id { $0?.parentClosed = true }
        }
      }
    parent?.close(promise: nil)
  }

  private func handle(_ message: SFTPMessage, context: ChannelHandlerContext) {
    if case .initialize = message {
      state.sftpInitializations.withLock { $0 += 1 }
      if state.faults.withLock({ $0.withholdVersionResponse }) { return }
      respond(.version(version: 3, extensions: []), context: context)
      return
    }
    guard let id = message.id else { return }
    let count = state.sftpRequests.withLock { n in
      n += 1
      return n
    }
    let shouldDrop = state.faults.withLock { plan -> Bool in
      guard let limit = plan.dropAfterRequests, count > limit else {
        return false
      }
      plan.dropAfterRequests = nil
      return true
    }
    if shouldDrop {
      dropConnection(
        context,
        requestID: id,
        message: message,
        cause: .requestLimit
      )
      return
    }
    let response = process(message, id: id, context: context)
    let (hold, holdAll) = state.faults.withLock { plan -> (Bool, Bool) in
      switch message {
      case .read where plan.holdAllReadResponses: return (true, true)
      case let .read(_, _, offset, _)
      where offset == 0 && plan.holdNextReadResponse:
        plan.holdNextReadResponse = false
        return (true, false)
      case let .write(_, _, offset, _)
      where offset == 0 && plan.holdNextWriteResponse:
        plan.holdNextWriteResponse = false
        return (true, false)
      case .open, .opendir:
        guard plan.holdNextOpenResponse else { return (false, false) }
        plan.holdNextOpenResponse = false
        return (true, false)
      case .realpath where plan.holdNextRealpathResponse:
        plan.holdNextRealpathResponse = false
        return (true, false)
      default: return (false, false)
      }
    }
    if hold {
      let loop = context.eventLoop
      let bound = NIOLoopBound(
        ResponseTarget(server: self, context: context),
        eventLoop: loop
      )
      let release: @Sendable () -> Void = {
        loop.execute {
          guard let server = bound.value.server,
            let context = bound.value.context
          else { return }
          server.respond(response, context: context)
        }
      }
      if holdAll {
        state.heldSFTPResponses.withLock { $0.append(release) }
      } else {
        state.heldSFTPResponse.withLock { $0 = release }
      }
    } else {
      respond(response, context: context)
    }
  }

  private func process(
    _ message: SFTPMessage,
    id: UInt32,
    context: ChannelHandlerContext
  ) -> SFTPMessage {
    switch message {
    case let .open(_, path, flags, attrs):
      guard let local = map(path) else { return status(id, .noSuchFile) }
      var oflags: Int32 = 0
      if flags.contains(.read), flags.contains(.write) {
        oflags = O_RDWR
      } else if flags.contains(.write) {
        oflags = O_WRONLY
      } else {
        oflags = O_RDONLY
      }
      if flags.contains(.create) { oflags |= O_CREAT }
      if flags.contains(.truncate) { oflags |= O_TRUNC }
      if flags.contains(.exclusive) { oflags |= O_EXCL }
      if flags.contains(.append) { oflags |= O_APPEND }
      let mode = mode_t(attrs.permissions.map { $0 & 0o777 } ?? 0o644)
      let fd = Darwin.open(local, oflags, mode)
      guard fd >= 0 else { return errnoStatus(id) }
      return .handle(id: id, register(.file(fd)))
    case let .close(_, handle):
      guard let key = key(handle), let item = items.removeValue(forKey: key)
      else { return status(id, .failure) }
      if case let .file(fd) = item { Darwin.close(fd) }
      state.sftpOpenHandles.withLock { $0 -= 1 }
      let reject = state.faults.withLock { plan in
        let reject = plan.rejectNextClose
        plan.rejectNextClose = false
        return reject
      }
      if reject { return status(id, .failure) }
      return status(id, .ok)
    case let .read(_, handle, offset, length):
      state.reads.withLock { $0 += 1 }
      guard let fd = fd(handle) else { return status(id, .failure) }
      var bytes = [UInt8](repeating: 0, count: Int(min(length, 65536)))
      let n = bytes.withUnsafeMutableBytes {
        pread(fd, $0.baseAddress, $0.count, off_t(offset))
      }
      if n < 0 { return errnoStatus(id) }
      if n == 0 { return status(id, .eof) }
      return .data(id: id, Array(bytes.prefix(n)))
    case let .write(_, handle, offset, data):
      guard let fd = fd(handle) else { return status(id, .failure) }
      state.writes.withLock { $0 += 1 }
      let n = data.withUnsafeBytes {
        pwrite(fd, $0.baseAddress, $0.count, off_t(offset))
      }
      return n == data.count ? status(id, .ok) : errnoStatus(id)
    case let .stat(_, path): return attributes(id, path: path, follow: true)
    case let .lstat(_, path): return attributes(id, path: path, follow: false)
    case let .fstat(_, handle):
      guard let fd = fd(handle) else { return status(id, .failure) }
      var info = Darwin.stat()
      guard fstat(fd, &info) == 0 else { return errnoStatus(id) }
      return .attrs(id: id, Self.attributes(info))
    case let .opendir(_, path):
      if state.faults.withLock({ $0.rejectedDirectoryPaths.contains(path) }) {
        return status(id, .permissionDenied)
      }
      guard let local = map(path),
        let names = try? FileManager.default.contentsOfDirectory(atPath: local)
      else { return status(id, .noSuchFile) }
      let entries = names.sorted()
        .map { name -> SFTPNameEntry in
          var info = Darwin.stat()
          lstat(local + "/" + name, &info)
          return SFTPNameEntry(
            filename: name,
            longname: name,
            attributes: Self.attributes(info)
          )
        }
      return .handle(id: id, register(.directory(entries)))
    case let .readdir(_, handle):
      guard let key = key(handle), case let .directory(entries) = items[key]
      else { return status(id, .failure) }
      state.directoryReads.withLock { $0 += 1 }
      let scripted = state.faults.withLock { plan -> [SFTPNameEntry]? in
        guard !plan.readDirectoryBatches.isEmpty else { return nil }
        return plan.readDirectoryBatches.removeFirst()
      }
      if let scripted { return .name(id: id, scripted) }
      if entries.isEmpty { return status(id, .eof) }
      items[key] = .directory(Array(entries.dropFirst(3)))
      return .name(id: id, Array(entries.prefix(3)))
    case let .remove(_, path):
      guard let local = map(path) else { return status(id, .noSuchFile) }
      return unlink(local) == 0 ? status(id, .ok) : errnoStatus(id)
    case let .realpath(_, path):
      let normalized = "/" + path.split(separator: "/").joined(separator: "/")
      return .name(
        id: id,
        [
          SFTPNameEntry(
            filename: normalized,
            longname: "",
            attributes: SFTPAttributes()
          )
        ]
      )
    case let .rename(_, old, new):
      guard let from = map(old), let to = map(new) else {
        return status(id, .noSuchFile)
      }
      // OpenSSH semantics: never replace an existing target.
      var info = Darwin.stat()
      if lstat(to, &info) == 0 { return status(id, .failure) }
      guard Darwin.rename(from, to) == 0 else { return errnoStatus(id) }
      state.renames.withLock { $0 += 1 }
      let drop = state.faults.withLock { plan -> Bool in
        defer { plan.dropRenameResponse = false }
        return plan.dropRenameResponse
      }
      if drop {
        dropConnection(context, requestID: id, message: message, cause: .rename)
        return status(id, .ok)  // never delivered: connection is closing
      }
      return status(id, .ok)
    case .extended: return status(id, .operationUnsupported)
    default: return status(id, .badMessage)
    }
  }

  // MARK: Helpers

  private func map(_ path: String) -> String? {
    let parts = path.split(separator: "/")
    guard !parts.contains("..") else { return nil }
    return root + "/" + parts.joined(separator: "/")
  }

  private func register(_ item: OpenItem) -> [UInt8] {
    let key = nextHandle
    nextHandle += 1
    items[key] = item
    state.sftpOpenHandles.withLock { $0 += 1 }
    return withUnsafeBytes(of: key.bigEndian) { Array($0) }
  }

  private func key(_ handle: [UInt8]) -> UInt32? {
    guard handle.count == 4 else { return nil }
    return handle.reduce(0) { $0 << 8 | UInt32($1) }
  }

  private func fd(_ handle: [UInt8]) -> Int32? {
    guard let key = key(handle), case let .file(fd) = items[key] else {
      return nil
    }
    return fd
  }

  private func status(_ id: UInt32, _ code: SFTPStatusCode) -> SFTPMessage {
    .status(id: id, SFTPStatus(code: code, message: "", language: ""))
  }

  private func errnoStatus(_ id: UInt32) -> SFTPMessage {
    switch errno {
    case ENOENT: status(id, .noSuchFile)
    case EACCES, EPERM: status(id, .permissionDenied)
    default: status(id, .failure)
    }
  }

  private func attributes(
    _ id: UInt32,
    path: String,
    follow: Bool
  ) -> SFTPMessage {
    guard let local = map(path) else { return status(id, .noSuchFile) }
    var info = Darwin.stat()
    let result = follow ? statFollowing(local, &info) : lstat(local, &info)
    guard result == 0 else { return errnoStatus(id) }
    var attributes = Self.attributes(info)
    if let size = state.faults.withLock({ $0.reportedFileSize }) {
      attributes.size = size
    }
    return .attrs(id: id, attributes)
  }

  private func statFollowing(
    _ path: String,
    _ info: UnsafeMutablePointer<Darwin.stat>
  ) -> Int32 { fstatat(AT_FDCWD, path, info, 0) }

  static func attributes(_ info: Darwin.stat) -> SFTPAttributes {
    SFTPAttributes(
      size: UInt64(info.st_size),
      uid: info.st_uid,
      gid: info.st_gid,
      permissions: UInt32(info.st_mode),
      accessTime: UInt32(truncatingIfNeeded: info.st_atimespec.tv_sec),
      modificationTime: UInt32(truncatingIfNeeded: info.st_mtimespec.tv_sec)
    )
  }
}
