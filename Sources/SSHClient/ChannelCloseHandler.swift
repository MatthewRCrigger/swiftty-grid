import NIOCore

/// NIOSSH waits for the peer's CHANNEL_CLOSE before completing child close.
/// Bound that wait for every local close, including handler error/timeout
/// paths. An activated child's failed close drops SSH because the SDK may
/// retain its channel ID without exposing the eventual acknowledgement.
final class ChannelCloseHandler: ChannelDuplexHandler {
  typealias InboundIn = Any
  typealias OutboundIn = Any
  static let acknowledgementTimeout = TimeAmount.seconds(5)

  private let parent: any Channel
  private var timer: Scheduled<Void>?
  private var closed = false
  private var activated = false

  init(parent: any Channel) { self.parent = parent }

  func handlerAdded(context: ChannelHandlerContext) {
    context.channel.closeFuture.assumeIsolated()
      .whenComplete { result in
        self.closed = true
        self.timer?.cancel()
        self.timer = nil
        if case .failure = result, self.activated, self.parent.isActive {
          // NIOSSH releases an errored child but keeps its ID until peer close.
          // Finish the SDK's error cleanup before closing its multiplexer.
          self.parent.eventLoop.execute { [parent = self.parent] in
            parent.close(promise: nil)
          }
        }
      }
  }

  func channelActive(context: ChannelHandlerContext) {
    activated = true
    context.fireChannelActive()
  }

  func close(
    context: ChannelHandlerContext,
    mode: CloseMode,
    promise: EventLoopPromise<Void>?,
  ) {
    if mode == .all, !closed, timer == nil {
      timer = context.eventLoop.scheduleTask(in: Self.acknowledgementTimeout) {
        [parent] in parent.close(promise: nil)
      }
    }
    context.close(mode: mode, promise: promise)
  }
}
