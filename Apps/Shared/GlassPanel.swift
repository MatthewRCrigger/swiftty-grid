import SwiftUI

/// GRID tokens for the shared SwiftUI surfaces: true-black void, hairline
/// strokes, one amber accent meaning "selected". The helpers below keep
/// their original names so callers do not change.
enum GridColor {
  static let surface0 = Color(red: 0, green: 0, blue: 0)
  static let surface1 = Color(red: 6 / 255, green: 8 / 255, blue: 9 / 255)
  static let surface2 = Color(red: 12 / 255, green: 16 / 255, blue: 19 / 255)
  static let line100 = Color(red: 0xd6 / 255, green: 0xea / 255, blue: 0xf2 / 255)
  static let line200 = Color(red: 0x8f / 255, green: 0xa8 / 255, blue: 0xb4 / 255)
  static let line300 = Color(red: 0x4a / 255, green: 0x5a / 255, blue: 0x63 / 255)
  static let ink100 = Color(red: 0xe4 / 255, green: 0xf2 / 255, blue: 0xf8 / 255)
  static let ink200 = Color(red: 0xa8 / 255, green: 0xbc / 255, blue: 0xc6 / 255)
  static let accent = Color(red: 0xf4 / 255, green: 0xbe / 255, blue: 0x4f / 255)
  static let accentOn = Color.black
}

/// Whether this platform keeps system glass (tinted with GRID) instead of
/// the flat hairline treatment: the one switch to change per platform.
private let keepsGlass: Bool = {
  #if os(visionOS) || os(tvOS)
  true
  #else
  false
  #endif
}()

/// A flat GRID button: hairline border and `ink-200` text, or a solid
/// accent fill with black text when prominent.
struct GridButtonStyle: ButtonStyle {
  var prominent = false
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 14, weight: .semibold))
      .foregroundStyle(
        prominent ? GridColor.accentOn : (isEnabled ? GridColor.ink200 : GridColor.line300)
      )
      .padding(.horizontal, 14)
      .frame(minHeight: 36)
      .background(
        prominent ? GridColor.accent.opacity(configuration.isPressed ? 0.7 : 1) : Color.clear
      )
      .overlay(
        Rectangle().stroke(
          prominent ? GridColor.accent : (configuration.isPressed ? GridColor.line100 : GridColor.line300),
          lineWidth: 1
        )
      )
      .contentShape(Rectangle())
  }
}

extension View {
  @ViewBuilder
  func glassPanel(cornerRadius: CGFloat = 12, tint: Color? = nil) -> some View {
    #if os(visionOS)
    background(tint ?? GridColor.accent.opacity(0.0))
      .glassBackgroundEffect(in: .rect(cornerRadius: cornerRadius))
    #elseif os(tvOS)
    glassEffect(.regular.tint(tint ?? GridColor.line300.opacity(0.2)), in: .rect(cornerRadius: cornerRadius))
    #else
    // Round panel profile: 2px border, 8px corners at most.
    let radius = cornerRadius == 0 ? 0 : min(cornerRadius, 8)
    background(tint ?? GridColor.surface1)
      .clipShape(.rect(cornerRadius: radius))
      .overlay(
        RoundedRectangle(cornerRadius: radius)
          .stroke(GridColor.line200, lineWidth: radius == 0 ? 1 : 2)
      )
    #endif
  }

  @ViewBuilder
  func glassSurface() -> some View {
    if keepsGlass {
      background { Color.clear.glassPanel(cornerRadius: 0).ignoresSafeArea() }
    } else {
      background { GridColor.surface0.ignoresSafeArea() }
    }
  }

  @ViewBuilder
  func glassListBackground() -> some View {
    #if os(tvOS)
    glassSurface()
    #else
    scrollContentBackground(.hidden).glassSurface()
    #endif
  }

  @ViewBuilder
  func glassButtonStyle(prominent: Bool = false) -> some View {
    #if os(visionOS)
    if prominent {
      buttonStyle(.borderedProminent).tint(GridColor.accent)
    } else {
      buttonStyle(.bordered)
    }
    #elseif os(tvOS)
    if prominent {
      buttonStyle(.glassProminent).tint(GridColor.accent)
    } else {
      buttonStyle(.glass)
    }
    #else
    buttonStyle(GridButtonStyle(prominent: prominent))
    #endif
  }

  @ViewBuilder
  func glassWindowBackground() -> some View {
    #if os(macOS)
    containerBackground(GridColor.surface0, for: .window)
    #else
    self
    #endif
  }
}
