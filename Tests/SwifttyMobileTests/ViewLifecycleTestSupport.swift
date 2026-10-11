import TestSupport
#if canImport(UIKit)
import Metal
import SwifttyCore
@testable import SwifttyMobile
import Synchronization
import Testing
import UIKit

@MainActor
final class ReviewHardwareKey: UIKey {
  let usage: Int
  init(_ usage: Int) {
    self.usage = usage
    super.init()
  }

  required init?(coder: NSCoder) { return nil }

  override var keyCode: UIKeyboardHIDUsage {
    UIKeyboardHIDUsage(rawValue: usage)!
  }
}

@MainActor
final class ReviewKeyPress: UIPress {
  let simulatedKey: UIKey
  init(_ usage: Int) {
    simulatedKey = ReviewHardwareKey(usage)
    super.init()
  }

  override var key: UIKey? { simulatedKey }
}

@MainActor
final class ReviewTapGesture: UITapGestureRecognizer {
  var point = CGPoint.zero
  override func location(in view: UIView?) -> CGPoint { point }
}

@MainActor
final class ReviewHoverGesture: UIHoverGestureRecognizer {
  private var simulatedState: UIGestureRecognizer.State = .possible
  var point = CGPoint.zero
  var flags: UIKeyModifierFlags = []
  override var state: UIGestureRecognizer.State {
    get { simulatedState }
    set { simulatedState = newValue }
  }

  override var modifierFlags: UIKeyModifierFlags { flags }

  override func location(in view: UIView?) -> CGPoint { point }
}

@MainActor
final class ReviewPinchGesture: UIPinchGestureRecognizer {
  private var simulatedState: UIGestureRecognizer.State = .possible
  override var state: UIGestureRecognizer.State {
    get { simulatedState }
    set { simulatedState = newValue }
  }
}

@MainActor
final class ReviewLongPressGesture: UILongPressGestureRecognizer {
  private var simulatedState: UIGestureRecognizer.State = .possible
  var point = CGPoint.zero
  override var state: UIGestureRecognizer.State {
    get { simulatedState }
    set { simulatedState = newValue }
  }

  override func location(in view: UIView?) -> CGPoint { point }
}

#endif
