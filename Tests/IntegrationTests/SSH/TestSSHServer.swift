import Crypto
import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import ScreenProtocol
import SessionCore
import Synchronization

@testable import SSHClient

/// Fault injection for the in-process SFTP server.
struct SFTPFaultPlan: Sendable {
  /// Close the whole SSH connection, without replying, when the request
  /// count exceeds this value (one-shot).
  var dropAfterRequests: Int?
  /// Perform the next rename, then drop the connection without replying
  /// (one-shot).
  var dropRenameResponse = false
}

/// Observable server-side state shared with tests.
final class TestServerState: Sendable {
  let authRequests = Mutex(0)
  let sftpRequests = Mutex(0)
  let renames = Mutex(0)
  let writes = Mutex(0)
  let faults = Mutex(SFTPFaultPlan())
  let ptyRequest = Mutex<SSHChannelRequestEvent.PseudoTerminalRequest?>(nil)
  let windowSize = Mutex<(Int, Int)?>(nil)
  let bootstrapRequests = Mutex<[BootstrapRequest]>([])
  /// When set, `forwardHelperPath bootstrap --stdio` hands its stdin
  /// envelope to this responder (a real `BootstrapService`).
  let bootstrapForwarder = Mutex<(@Sendable ([UInt8]) async -> [UInt8])?>(nil)
}

final class TestAuthDelegate: NIOSSHServerUserAuthenticationDelegate, Sendable
{
  let username: String
  let password: String
  let authorizedKeys: [NIOSSHPublicKey]
  let state: TestServerState

  init(
    username: String,
    password: String,
    authorizedKeys: [NIOSSHPublicKey],
    state: TestServerState
  ) {
    self.username = username
    self.password = password
    self.authorizedKeys = authorizedKeys
    self.state = state
  }

  var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods {
    [.password, .publicKey]
  }

  func requestReceived(
    request: NIOSSHUserAuthenticationRequest,
    responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
  ) {
    state.authRequests.withLock { $0 += 1 }
    guard request.username == username else {
      responsePromise.succeed(.failure)
      return
    }
    switch request.request {
    case let .password(offer):
      responsePromise.succeed(offer.password == password ? .success : .failure)
    case let .publicKey(offer):
      responsePromise.succeed(
        authorizedKeys.contains(offer.publicKey) ? .success : .failure
      )
    default:
      responsePromise.succeed(.failure)
    }
  }
}

/// In-process NIOSSH server on 127.0.0.1 with an ephemeral port.
final class TestSSHServer: Sendable {
  static let username = "tester"
  static let password = "correct horse"
  static let helperPath = "/usr/local/libexec/swifttyd"
  static let forwardHelperPath = "/opt/forward/swifttyd"

  let channel: any Channel
  let port: Int
  let hostKey: NIOSSHPrivateKey
  let state: TestServerState
  /// SFTP root; absolute request paths resolve beneath it.
  let root: URL

  private init(
    channel: any Channel,
    port: Int,
    hostKey: NIOSSHPrivateKey,
    state: TestServerState,
    root: URL
  ) {
    self.channel = channel
    self.port = port
    self.hostKey = hostKey
    self.state = state
    self.root = root
  }

  var hostKeyLine: String { String(openSSHPublicKey: hostKey.publicKey) }

  var identity: HostIdentity { HostIdentity(host: "127.0.0.1", port: port)! }

  static func start(
    hostKey: NIOSSHPrivateKey = NIOSSHPrivateKey(ed25519Key: .init()),
    authorizedKeys: [NIOSSHPublicKey] = []
  ) async throws -> TestSSHServer {
    let state = TestServerState()
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("sftp-root-" + UUID().uuidString)
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true
    )
    let auth = TestAuthDelegate(
      username: username,
      password: password,
      authorizedKeys: authorizedKeys,
      state: state
    )
    let rootPath = root.path
    let channel = try await ServerBootstrap(
      group: MultiThreadedEventLoopGroup.singleton
    )
    .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
    .childChannelInitializer { channel in
      channel.eventLoop.makeCompletedFuture {
        let ssh = NIOSSHHandler(
          role: .server(
            .init(hostKeys: [hostKey], userAuthDelegate: auth)
          ),
          allocator: channel.allocator,
          inboundChildChannelInitializer: { child, type in
            guard case .session = type else {
              return child.eventLoop.makeFailedFuture(
                SSHClientError.channelRequestRejected("type")
              )
            }
            return child.eventLoop.makeCompletedFuture {
              try child.pipeline.syncOperations.addHandler(
                TestSessionHandler(state: state, root: rootPath)
              )
            }
          }
        )
        try channel.pipeline.syncOperations.addHandler(ssh)
        try channel.pipeline.syncOperations.addHandler(CloseOnErrorHandler())
      }
    }
    .bind(host: "127.0.0.1", port: 0)
    .get()
    return TestSSHServer(
      channel: channel,
      port: channel.localAddress!.port!,
      hostKey: hostKey,
      state: state,
      root: root
    )
  }

  func shutdown() async {
    try? await channel.close()
    try? FileManager.default.removeItem(at: root)
  }

  func configuration() -> SSHClient.SSHClientConfiguration {
    SSHClient.SSHClientConfiguration(
      host: "127.0.0.1",
      port: port,
      username: Self.username,
      connectTimeout: .seconds(10)
    )
  }

  /// A store that already trusts this server's key.
  func trustingStore() -> InMemoryHostTrustStore {
    InMemoryHostTrustStore(keys: [identity: hostKeyLine])
  }

  func connect(
    credential: SSHCredential = .password(TestSSHServer.password)
  ) async throws -> SSHConnection {
    try await SSHConnection.connect(
      configuration: configuration(),
      credential: credential,
      trustStore: trustingStore(),
      trustDecider: RejectUnknownHostKeys()
    )
  }

  func url(_ path: String) -> URL {
    root.appendingPathComponent(
      String(path.drop(while: { $0 == "/" }))
    )
  }
}

final class CloseOnErrorHandler: ChannelInboundHandler, Sendable {
  typealias InboundIn = Any
  func errorCaught(context: ChannelHandlerContext, error: any Error) {
    context.close(promise: nil)
  }
}

/// Server side of one session channel: exec, shell (echo) or the SFTP
/// subsystem.
final class TestSessionHandler: ChannelInboundHandler {
  typealias InboundIn = SSHChannelData

  enum Mode { case idle, exec(String), shell, sftp }

  let state: TestServerState
  let sftp: TestSFTPServer
  var mode = Mode.idle
  var stdin: [UInt8] = []

  init(state: TestServerState, root: String) {
    self.state = state
    self.sftp = TestSFTPServer(root: root, state: state)
  }

  func handlerAdded(context: ChannelHandlerContext) {
    _ = context.channel.setOption(
      ChannelOptions.allowRemoteHalfClosure,
      value: true
    )
  }

  func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
    switch event {
    case let request as SSHChannelRequestEvent.ExecRequest:
      mode = .exec(request.command)
      reply(context, success: true, wantReply: request.wantReply)
      runExecIfImmediate(context, command: request.command)
    case let request as SSHChannelRequestEvent.PseudoTerminalRequest:
      state.ptyRequest.withLock { $0 = request }
      reply(context, success: true, wantReply: request.wantReply)
    case let request as SSHChannelRequestEvent.ShellRequest:
      mode = .shell
      reply(context, success: true, wantReply: request.wantReply)
    case let request as SSHChannelRequestEvent.WindowChangeRequest:
      state.windowSize.withLock {
        $0 = (request.terminalCharacterWidth, request.terminalRowHeight)
      }
      send(
        context,
        Array(
          "[resize \(request.terminalCharacterWidth)x\(request.terminalRowHeight)]"
            .utf8
        )
      )
    case let request as SSHChannelRequestEvent.SubsystemRequest:
      let ok = request.subsystem == "sftp"
      if ok { mode = .sftp }
      reply(context, success: ok, wantReply: request.wantReply)
    case let event as ChannelEvent where event == .inputClosed:
      if case let .exec(command) = mode {
        finishExec(context, command: command)
      }
    default:
      context.fireUserInboundEventTriggered(event)
    }
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    let message = unwrapInboundIn(data)
    guard case let .byteBuffer(buffer) = message.data else { return }
    let bytes = Array(buffer.readableBytesView)
    switch mode {
    case .exec: stdin += bytes
    case .shell:
      if bytes == Array("flood".utf8) {
        // 6 MiB burst for the read-credit test.
        for _ in 0 ..< 96 {
          send(context, [UInt8](repeating: 0x61, count: 64 * 1024))
        }
      } else {
        send(context, bytes)
      }
    case .sftp: sftp.receive(bytes, context: context)
    case .idle: break
    }
  }

  func errorCaught(context: ChannelHandlerContext, error: any Error) {
    context.close(promise: nil)
  }

  private func reply(
    _ context: ChannelHandlerContext,
    success: Bool,
    wantReply: Bool
  ) {
    guard wantReply else { return }
    let event: Any = success ? ChannelSuccessEvent() : ChannelFailureEvent()
    context.triggerUserOutboundEvent(event, promise: nil)
  }

  func send(
    _ context: ChannelHandlerContext,
    _ bytes: [UInt8],
    type: SSHChannelData.DataType = .channel
  ) {
    var buffer = context.channel.allocator.buffer(capacity: bytes.count)
    buffer.writeBytes(bytes)
    context.writeAndFlush(
      NIOAny(SSHChannelData(type: type, data: .byteBuffer(buffer))),
      promise: nil
    )
  }

  func exit(_ context: ChannelHandlerContext, status: Int) {
    context.triggerUserOutboundEvent(
      SSHChannelRequestEvent.ExitStatus(exitStatus: status),
      promise: nil
    )
    context.close(promise: nil)
  }

  /// Commands that do not read stdin start immediately.
  private func runExecIfImmediate(
    _ context: ChannelHandlerContext,
    command: String
  ) {
    switch command {
    case "flood-stdout":
      for _ in 0 ..< 32 {
        send(context, [UInt8](repeating: 0x62, count: 64 * 1024))
      }
      exit(context, status: 0)
    default: break
    }
  }

  private func finishExec(_ context: ChannelHandlerContext, command: String) {
    let suffix = " bootstrap --stdio"
    switch command {
    case "echo-split":
      send(context, Array("out:".utf8) + stdin)
      send(context, Array("err".utf8), type: .stdErr)
      exit(context, status: 3)
    case TestSSHServer.helperPath + suffix:
      send(context, Array("helper diagnostics".utf8), type: .stdErr)
      send(context, bootstrapReply())
      exit(context, status: 0)
    case TestSSHServer.forwardHelperPath + suffix:
      guard let forward = state.bootstrapForwarder.withLock({ $0 }) else {
        exit(context, status: 1)
        return
      }
      let input = stdin
      let bound = NIOLoopBound((self, context), eventLoop: context.eventLoop)
      let loop = context.eventLoop
      Task {
        let reply = await forward(input)
        loop.execute {
          let (handler, context) = bound.value
          handler.send(context, reply)
          handler.exit(context, status: 0)
        }
      }
    case "/opt/garbage/swifttyd" + suffix:
      send(context, bootstrapReply() + Array("x".utf8))
      exit(context, status: 0)
    case "/opt/banner/swifttyd" + suffix:
      send(context, Array("Welcome!\n".utf8) + bootstrapReply())
      exit(context, status: 0)
    case "/opt/noisy/swifttyd" + suffix:
      for _ in 0 ..< 8 {
        send(
          context,
          [UInt8](repeating: 0x21, count: 16 * 1024),
          type: .stdErr
        )
      }
      send(context, bootstrapReply())
      exit(context, status: 0)
    case "/opt/silent/swifttyd" + suffix:
      send(context, Array("agent unavailable".utf8), type: .stdErr)
      exit(context, status: 1)
    default:
      exit(context, status: 127)
    }
  }

  private func bootstrapReply() -> [UInt8] {
    let response: BootstrapResponse
    if let request = try? BootstrapEnvelope.decode(
      BootstrapRequest.self,
      from: stdin
    ) {
      state.bootstrapRequests.withLock { $0.append(request) }
      response =
        switch request.operation {
        case .list: .sessions([])
        case .terminate: .terminated(request.sessionID!)
        default: .failure(.unknownSession)
        }
    } else {
      response = .failure(.malformed)
    }
    return (try? BootstrapEnvelope.encode(response)) ?? []
  }
}
