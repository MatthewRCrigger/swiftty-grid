#if os(visionOS)
import SwiftUI
import UIKit

@MainActor
final class VisionGlassBackground: UIView {
  let contentView = UIView()

  init(cornerRadius: CGFloat = 0) {
    super.init(frame: .zero)
    isOpaque = false
    contentView.isOpaque = false
    let glass = UIHostingConfiguration {
      Color.clear.glassBackgroundEffect(in: .rect(cornerRadius: cornerRadius))
    }
    .margins(.all, 0).makeContentView()
    glass.isUserInteractionEnabled = false
    glass.backgroundColor = .clear
    for view in [glass, contentView] {
      view.frame = bounds
      view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      addSubview(view)
    }
    layer.cornerRadius = cornerRadius
    clipsToBounds = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }
}
#endif
