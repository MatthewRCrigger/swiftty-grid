import SwiftMuxProtocol

/// Builds only the next record, preserving complete Unicode scalars.
package struct MuxTextChunks: Sequence, Sendable {
  private let text: String
  private let maxBytes: Int

  package init(_ text: String, maxBytes: Int) {
    self.text = text
    self.maxBytes = Swift.max(1, maxBytes)
  }

  package func makeIterator() -> Iterator {
    Iterator(scalars: text.unicodeScalars.makeIterator(), maxBytes: maxBytes)
  }

  package struct Iterator: IteratorProtocol {
    fileprivate var scalars: String.UnicodeScalarView.Iterator
    fileprivate let maxBytes: Int
    private var pending: Unicode.Scalar?

    fileprivate init(scalars: String.UnicodeScalarView.Iterator, maxBytes: Int, )
    {
      self.scalars = scalars
      self.maxBytes = maxBytes
    }

    package mutating func next() -> String? {
      var chunk = String.UnicodeScalarView()
      var bytes = 0
      while let scalar = pending ?? scalars.next() {
        pending = nil
        let width = UTF8.width(scalar)
        if bytes + width > maxBytes, !chunk.isEmpty {
          pending = scalar
          return String(chunk)
        }
        chunk.append(scalar)
        bytes += width
      }
      return chunk.isEmpty ? nil : String(chunk)
    }
  }
}
