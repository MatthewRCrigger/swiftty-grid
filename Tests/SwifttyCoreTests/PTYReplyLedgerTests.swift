@testable import SwifttyCore
import Testing

struct PTYReplyLedgerTests {
  @Test
  func sustainedMixedRangesMatchTheUnwrittenByteStream() {
    var ledger = PTYReplyLedger()
    ledger.append(count: 64, isReply: false)
    var model = [Bool](repeating: false, count: 64)
    var cursor = 0
    var pendingReplies = 0
    for turn in 0 ..< 1600 {
      ledger.append(count: 32, isReply: false)
      model.append(contentsOf: repeatElement(false, count: 32))
      // Exercise both contiguous reply merging and separated reply ranges.
      if turn.isMultiple(of: 3) {
        ledger.append(count: 8, isReply: true)
        ledger.append(count: 8, isReply: true)
      } else {
        ledger.append(count: 16, isReply: true)
      }
      model.append(contentsOf: repeatElement(true, count: 16))
      pendingReplies += 16
      let consumed = 32
      pendingReplies -= model[cursor ..< cursor + consumed].filter(\.self).count
      cursor += consumed
      ledger.consumed(consumed)
      #expect(ledger.byteCount == pendingReplies)
    }
    // The writer never emptied during the loop; draining it must reset
    // positions before a fresh mixed stream begins.
    ledger.consumed(model.count - cursor)
    #expect(ledger.byteCount == 0)
    ledger.append(count: 9, isReply: true)
    ledger.append(count: 7, isReply: false)
    ledger.consumed(4)
    #expect(ledger.byteCount == 5)
    ledger.consumed(5)
    #expect(ledger.byteCount == 0)
    ledger.append(count: 3, isReply: true)
    ledger.consumed(7)
    #expect(ledger.byteCount == 3)
    ledger.consumed(3)
    #expect(ledger.byteCount == 0)
  }
}
