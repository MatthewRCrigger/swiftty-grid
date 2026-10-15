import CoreGraphics
import CoreText
import Foundation

struct FontFaceResolver {
  let descriptor: FontDescriptor
  private var pixelSize: CGFloat { descriptor.size * descriptor.scale }

  func named(_ family: String) -> CTFont? {
    let font = CTFontCreateWithName(family as CFString, pixelSize, nil)
    // CoreText also accepts PostScript and full face names. Check
    // those names to distinguish a match from its default font.
    let names = [
      CTFontCopyFamilyName(font), CTFontCopyPostScriptName(font),
      CTFontCopyFullName(font), CTFontCopyDisplayName(font),
    ]
    return names.contains {
      ($0 as String).caseInsensitiveCompare(family) == .orderedSame
    } ? font : nil
  }

  /// The face of `font`'s family whose style name is `style`.
  func face(_ style: String, in font: CTFont) -> CTFont? {
    let attributes: [CFString: Any] = [
      kCTFontFamilyNameAttribute: CTFontCopyFamilyName(font),
      kCTFontStyleNameAttribute: style,
    ]
    let match = CTFontCreateWithFontDescriptor(
      CTFontDescriptorCreateWithAttributes(attributes as CFDictionary),
      pixelSize,
      nil
    )
    // CoreText substitutes the closest face when no style matches.
    guard
      CTFontCopyFamilyName(match) as String == CTFontCopyFamilyName(font)
        as String,
      let name = CTFontCopyName(match, kCTFontStyleNameKey) as String?,
      name.caseInsensitiveCompare(style) == .orderedSame
    else { return nil }
    return match
  }

  func styled(
    _ regular: CTFont,
    _ traits: CTFontSymbolicTraits,
    family: String? = nil,
    style: FaceStyle = .default
  ) -> (CTFont, Bool) {
    let familyFont = family.flatMap(named)
    switch style {
    case .disabled: return (regular, false)
    case .named(let name):
      if let font = face(name, in: familyFont ?? regular) {
        return (font, false)
      }
    case .default: break
    }
    if let familyFont { return (familyFont, false) }
    if let font = CTFontCreateCopyWithSymbolicTraits(
      regular,
      pixelSize,
      nil,
      traits,
      traits
    ) {
      return (font, false)
    }
    // No such face: synthesize from the closest one.
    let bold = traits.contains(.traitBold)
    let italic = traits.contains(.traitItalic)
    let synthesize =
      bold && italic
      ? descriptor.synthesizeBoldItalic
      : bold ? descriptor.synthesizeBold : descriptor.synthesizeItalic
    guard synthesize else { return (regular, false) }
    let boldFace =
      bold
      ? CTFontCreateCopyWithSymbolicTraits(
        regular,
        pixelSize,
        nil,
        .traitBold,
        .traitBold
      ) : nil
    let embolden = bold && boldFace == nil
    let base = boldFace ?? regular
    guard italic else { return (base, embolden) }
    var skew = CGAffineTransform(a: 1, b: 0, c: 0.2, d: 1, tx: 0, ty: 0)
    return (
      CTFontCreateWithFontDescriptor(
        CTFontCopyFontDescriptor(base),
        pixelSize,
        &skew
      ), embolden
    )
  }
}
