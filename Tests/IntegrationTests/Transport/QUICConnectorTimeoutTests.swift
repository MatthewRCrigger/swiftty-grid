import Network
import ScreenProtocol
import Testing

@testable import AppleTransport

/// A handshake that times out says what path state Network framework was
/// waiting in, so "timed out" is not the only diagnosis a user sees.
@Suite
struct QUICConnectorTimeoutTests {
  @Test
  func timeoutNamesTheWaitingReason() {
    let waiting = String(describing: NWError.posix(.ENETUNREACH))
    #expect(
      QUICRSTConnector.timeout(.handshake("timed out"), waiting: waiting)
        == .handshake("timed out while waiting for a network path: \(waiting)")
    )
  }

  @Test
  func otherErrorsAndUnreportedWaitsPassThrough() {
    #expect(
      QUICRSTConnector.timeout(.handshake("timed out"), waiting: nil)
        == .handshake("timed out")
    )
    #expect(
      QUICRSTConnector.timeout(.handshake("timed out"), waiting: "")
        == .handshake("timed out")
    )
    #expect(
      QUICRSTConnector.timeout(.pinMismatch, waiting: "anything")
        == .pinMismatch
    )
    #expect(
      QUICRSTConnector.timeout(.handshake("no control stream"), waiting: "x")
        == .handshake("no control stream")
    )
  }
}
