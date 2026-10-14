/// Counts only replies in an ordered mixture of queued user input and
/// terminal replies. Positions refer to the live writer stream, independent
/// of the byte slice's backing storage and prefix compaction.
struct PTYReplyLedger {
  private var head = 0
  private var tail = 0
  private var replies: ArraySlice<Range<Int>> = []
  private(set) var byteCount = 0

  mutating func append(count: Int, isReply: Bool) {
    let end = tail + count
    if isReply {
      if let last = replies.last, last.upperBound == tail {
        replies[replies.endIndex - 1] = last.lowerBound ..< end
      } else {
        replies.append(tail ..< end)
      }
      byteCount += count
    }
    tail = end
  }

  mutating func consumed(_ count: Int) {
    head += count
    while let first = replies.first, head > first.lowerBound {
      byteCount -= min(head, first.upperBound) - first.lowerBound
      if head >= first.upperBound {
        replies.removeFirst()
      } else {
        replies[replies.startIndex] = head ..< first.upperBound
        break
      }
    }
    if head == tail {
      self = Self()
    } else if replies.isEmpty {
      replies = []
    } else if replies.startIndex >= 512 {
      replies = ArraySlice(Array(replies))
    }
  }
}
