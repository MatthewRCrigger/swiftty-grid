import CoreGraphics
import CoreText
import Foundation
import Metal

/// Shelf-packed RGBA glyph atlas filled by CoreText rasterization.
final class GlyphAtlas {
  struct Entry {
    var position: SIMD2<UInt16>
    var size: SIMD2<UInt16>
    var offset: SIMD2<Int16>
    var isColor: Bool
    static let empty = Entry(
      position: .zero,
      size: .zero,
      offset: .zero,
      isColor: false
    )
  }

  private(set) var size = 2048
  private(set) var texture: MTLTexture
  private let device: MTLDevice
  private let maximumSize: Int
  private var needsReset = false
  private var needsMetadataReset = false
  private let metadataLimit: Int
  /// Conservative cache cost: dictionary overhead plus variable key storage.
  private(set) var cachedMetadataCost = 0
  private var entries: [UInt64: Entry] = [:]
  private var clusters = GlyphClusterCache()
  private var glyphs: [GlyphKey: Entry] = [:]
  private var shapedCells: [[PositionedGlyphKey]: Entry] = [:]

  private struct PositionedGlyphKey: Hashable {
    var glyph: GlyphKey
    var x: CGFloat
    var y: CGFloat
    var isColor: Bool
  }

  /// A glyph in a specific CTFont; fonts compare with CFEqual, which
  /// covers the matrix, so a synthetic oblique never collides with upright.
  struct GlyphKey: Hashable {
    var font: CTFont
    var glyph: CGGlyph
    var embolden: Bool

    static func == (a: GlyphKey, b: GlyphKey) -> Bool {
      a.glyph == b.glyph && a.embolden == b.embolden && CFEqual(a.font, b.font)
    }

    func hash(into hasher: inout Hasher) {
      hasher.combine(glyph)
      hasher.combine(embolden)
      hasher.combine(CFHash(font))
    }
  }

  private var cursorX = 0, cursorY = 0, shelfHeight = 0
  private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
  /// Set when the atlas was cleared; cached instances are stale.
  var wasReset = false

  /// A glyph did not fit while building the current frame.
  var needsFrameRetry: Bool { needsReset }

  init(
    device: MTLDevice,
    size: Int = 2048,
    maximumSize: Int = 8192,
    metadataLimit: Int = 8 * 1024 * 1024
  ) throws {
    precondition(size > 0 && maximumSize >= size && maximumSize <= 8192)
    precondition(metadataLimit >= 128)
    self.device = device
    self.size = size
    self.maximumSize = maximumSize
    self.metadataLimit = metadataLimit
    let d = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .rgba8Unorm,
      width: size,
      height: size,
      mipmapped: false
    )
    d.usage = .shaderRead
    d.storageMode = .shared
    guard let texture = device.makeTexture(descriptor: d) else {
      throw RendererError.setup("atlas texture")
    }
    self.texture = texture
  }

  func reset() {
    needsReset = false
    needsMetadataReset = false
    cachedMetadataCost = 0
    entries.removeAll(keepingCapacity: true)
    clusters.removeAll(keepingCapacity: true)
    glyphs.removeAll(keepingCapacity: true)
    shapedCells.removeAll(keepingCapacity: true)
    cursorX = 0
    cursorY = 0
    shelfHeight = 0
    wasReset = true
  }

  /// Called only after the previous GPU frame has finished. If the cache
  /// reached its memory limit, start this frame with room for its own glyphs.
  func prepareForFrame() { if needsReset || needsMetadataReset { reset() } }

  private func reserveMetadata(
    elements: Int = 0,
    stride: Int = 1,
    overhead: Int = 128
  ) -> Bool {
    // Oversized keys cannot become cacheable by clearing other entries.
    guard elements <= (metadataLimit - overhead) / stride else { return false }
    let cost = overhead + elements * stride
    guard cost <= metadataLimit - cachedMetadataCost else {
      needsMetadataReset = true
      return false
    }
    cachedMetadataCost += cost
    return true
  }

  private func makeRoom(width: Int, height: Int) -> Bool {
    while width > size || height > size {
      guard !needsReset, grow() else {
        needsReset = true
        return false
      }
    }
    if cursorX + width > size {
      cursorX = 0
      cursorY += shelfHeight
      shelfHeight = 0
    }
    while cursorY + height > size {
      guard !needsReset, grow() else {
        // Never overwrite pixels referenced by this frame. Retry
        // with an empty cache at the next frame boundary instead.
        needsReset = true
        return false
      }
    }
    return true
  }

  private func grow() -> Bool {
    // Bound cache memory to 256 MiB; allocation can fail sooner on a
    // device with a smaller texture limit or memory budget.
    guard size < maximumSize else { return false }
    let larger = min(maximumSize, size * 2)
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .rgba8Unorm,
      width: larger,
      height: larger,
      mipmapped: false,
    )
    descriptor.usage = .shaderRead
    descriptor.storageMode = .shared
    guard let expanded = device.makeTexture(descriptor: descriptor) else {
      return false
    }
    let pixels = UnsafeMutableRawPointer.allocate(
      byteCount: size * size * 4,
      alignment: 16
    )
    defer { pixels.deallocate() }
    let region = MTLRegionMake2D(0, 0, size, size)
    texture.getBytes(
      pixels,
      bytesPerRow: size * 4,
      from: region,
      mipmapLevel: 0
    )
    expanded.replace(
      region: region,
      mipmapLevel: 0,
      withBytes: pixels,
      bytesPerRow: size * 4
    )
    texture = expanded
    size = larger
    return true
  }

  func entry(
    scalar: Unicode.Scalar,
    style: FontStyle,
    font: ResolvedFont,
    manager: CoreTextFontManager
  ) -> Entry {
    let key = UInt64(scalar.value) | UInt64(style.rawValue) << 32
    if let entry = entries[key] { return entry }
    var entry = Entry.empty
    if BoxDrawing.covers(scalar.value) {
      entry = rasterizeCell(font: font) { ctx, w, h in
        BoxDrawing.draw(scalar.value, in: ctx, width: w, height: h)
      }
    } else if let lookup = manager.lookup(scalar, style: style, in: font) {
      var glyph = lookup.glyph
      var rect = CGRect.zero
      CTFontGetBoundingRectsForGlyphs(
        lookup.font,
        .horizontal,
        &glyph,
        &rect,
        1
      )
      let embolden = font.shouldEmbolden(lookup.font, style: style)
      entry = rasterize(
        bounds: rect,
        isColor: lookup.isColor,
        embolden: embolden,
        font: font
      ) { context, origin in
        var position = origin
        CTFontDrawGlyphs(lookup.font, &glyph, &position, 1, context)
      }
    }
    if reserveMetadata() { entries[key] = entry }
    return entry
  }

  /// A shaped glyph, keyed by its font and glyph id.
  func entry(
    glyph: CGGlyph,
    in glyphFont: CTFont,
    isColor: Bool,
    embolden: Bool = false,
    font: ResolvedFont
  ) -> Entry {
    let key = GlyphKey(
      font: glyphFont,
      glyph: glyph,
      embolden: embolden && !isColor
    )
    if let entry = glyphs[key] { return entry }
    var g = glyph
    var rect = CGRect.zero
    CTFontGetBoundingRectsForGlyphs(glyphFont, .horizontal, &g, &rect, 1)
    let entry = rasterize(
      bounds: rect,
      isColor: isColor,
      embolden: key.embolden,
      font: font
    ) { context, origin in
      var position = origin
      CTFontDrawGlyphs(glyphFont, &g, &position, 1, context)
    }
    if reserveMetadata() { glyphs[key] = entry }
    return entry
  }

  /// Packs every positioned glyph belonging to one shaped terminal cell.
  /// The common single-glyph case shares the ordinary glyph cache.
  func entry(
    glyphs: ArraySlice<Shaper.Glyph>,
    style: FontStyle,
    font: ResolvedFont
  ) -> Entry {
    guard let first = glyphs.first else { return .empty }
    if glyphs.count == 1 {
      return entry(
        glyph: first.glyph,
        in: first.font,
        isColor: first.isColor,
        embolden: font.shouldEmbolden(first.font, style: style),
        font: font,
      )
    }
    let key = glyphs.map {
      PositionedGlyphKey(
        glyph: GlyphKey(
          font: $0.font,
          glyph: $0.glyph,
          embolden: font.shouldEmbolden($0.font, style: style)
        ),
        x: $0.offset.x,
        y: $0.offset.y,
        isColor: $0.isColor,
      )
    }
    if let cached = shapedCells[key] { return cached }
    var bounds = CGRect.null
    for part in key {
      var glyph = part.glyph.glyph
      let rect = CTFontGetBoundingRectsForGlyphs(
        part.glyph.font,
        .horizontal,
        &glyph,
        nil,
        1
      )
      bounds = bounds.union(rect.offsetBy(dx: part.x, dy: part.y))
    }
    let entry = rasterize(
      bounds: bounds,
      isColor: key.contains { $0.isColor },
      embolden: key.contains { $0.glyph.embolden },
      font: font,
    ) { context, origin in
      for part in key {
        var glyph = part.glyph.glyph
        var position = CGPoint(x: origin.x + part.x, y: origin.y + part.y)
        context.setTextDrawingMode(part.glyph.embolden ? .fillStroke : .fill)
        CTFontDrawGlyphs(part.glyph.font, &glyph, &position, 1, context)
      }
    }
    if reserveMetadata(
      elements: key.count,
      stride: MemoryLayout<PositionedGlyphKey>.stride
    ) {
      shapedCells[key] = entry
    }
    return entry
  }

  func entry(
    cluster scalars: [UInt32],
    style: FontStyle,
    font: ResolvedFont
  ) -> Entry {
    let span = scalars.span
    return entry(cluster: span, style: style, font: font)
  }

  func entry(
    cluster scalars: borrowing Span<UInt32>,
    style: FontStyle,
    font: ResolvedFont
  ) -> Entry {
    let hash = GlyphClusterCache.hash(scalars, style: style.rawValue)
    if let entry = clusters.entry(
      for: scalars,
      style: style.rawValue,
      hash: hash
    ) {
      return entry
    }
    var string = String.UnicodeScalarView()
    for v in scalars { if let s = Unicode.Scalar(v) { string.append(s) } }
    let attributed = NSAttributedString(
      string: String(string),
      attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font.face(
          style
        ),
        NSAttributedString.Key(
          kCTForegroundColorFromContextAttributeName as String
        ): true,
      ]
    )
    let line = CTLineCreateWithAttributedString(attributed)
    let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
    let isColor = runs.contains { run in
      let attrs = CTRunGetAttributes(run) as NSDictionary
      let runFont = attrs[kCTFontAttributeName] as! CTFont
      return CTFontGetSymbolicTraits(runFont).contains(.traitColorGlyphs)
    }
    let emboldened = runs.map { run in
      let attrs = CTRunGetAttributes(run) as NSDictionary
      return font.shouldEmbolden(
        attrs[kCTFontAttributeName] as! CTFont,
        style: style
      )
    }
    let embolden = emboldened.contains(true)
    let entry = rasterize(
      bounds: bounds,
      isColor: isColor,
      embolden: embolden,
      font: font
    ) { context, origin in
      for (index, run) in runs.enumerated() {
        context.textPosition = origin
        context.setTextDrawingMode(emboldened[index] ? .fillStroke : .fill)
        CTRunDraw(run, context, CFRange(location: 0, length: 0))
      }
    }
    let record = GlyphClusterCache.Record(
      scalars: scalars,
      style: style.rawValue,
      value: entry
    )
    if reserveMetadata(
      elements: record.scalarCapacity,
      stride: MemoryLayout<UInt32>.stride,
      overhead: GlyphClusterCache.metadataOverhead,
    ) {
      clusters.insert(record, hash: hash)
    }
    return entry
  }

  /// Draws a bitmap exactly one cell in size, placed at the cell's origin.
  private func rasterizeCell(
    font: ResolvedFont,
    draw: (CGContext, CGFloat, CGFloat) -> Void
  ) -> Entry {
    guard font.cellWidth >= 1, font.cellHeight >= 1,
      font.cellWidth < CGFloat(maximumSize),
      font.cellHeight < CGFloat(maximumSize)
    else { return .empty }
    let width = Int(font.cellWidth)
    let height = Int(font.cellHeight)
    guard makeRoom(width: width, height: height) else { return .empty }
    guard
      let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
      )
    else { return .empty }
    context.setShouldAntialias(true)
    draw(context, CGFloat(width), CGFloat(height))
    guard let data = context.data else { return .empty }
    texture.replace(
      region: MTLRegionMake2D(cursorX, cursorY, width, height),
      mipmapLevel: 0,
      withBytes: data,
      bytesPerRow: width * 4
    )
    let entry = Entry(
      position: SIMD2(UInt16(cursorX), UInt16(cursorY)),
      size: SIMD2(UInt16(width), UInt16(height)),
      offset: .zero,
      isColor: false,
    )
    cursorX += width
    shelfHeight = max(shelfHeight, height)
    return entry
  }

  /// Draws into a scratch bitmap sized to `bounds` and uploads it.
  private func rasterize(
    bounds: CGRect,
    isColor: Bool,
    embolden: Bool = false,
    font: ResolvedFont,
    draw: (CGContext, CGPoint) -> Void,
  ) -> Entry {
    // Synthetic bold strokes the outline, growing it by half the width.
    let stroke =
      embolden
      ? max(1, (font.descriptor.size * font.descriptor.scale / 32).rounded())
      : 0
    let bounds = bounds.insetBy(dx: -stroke / 2, dy: -stroke / 2)
    let pad = 1
    guard bounds.width > 0, bounds.height > 0,
      ceil(bounds.width) + CGFloat(2 * pad) < CGFloat(maximumSize),
      ceil(bounds.height) + CGFloat(2 * pad) < CGFloat(maximumSize)
    else { return .empty }
    let width = Int(ceil(bounds.width)) + 2 * pad
    let height = Int(ceil(bounds.height)) + 2 * pad
    let originX = -floor(bounds.minX) + CGFloat(pad)
    let originY = -floor(bounds.minY) + CGFloat(pad)
    guard let offsetX = Int16(exactly: -originX),
      let offsetY = Int16(exactly: font.ascent - (CGFloat(height) - originY))
    else { return .empty }
    guard makeRoom(width: width, height: height) else { return .empty }

    guard
      let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
      )
    else { return .empty }
    context.setAllowsFontSmoothing(false)
    context.setShouldAntialias(true)
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    if embolden {
      context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
      context.setLineWidth(stroke)
      context.setTextDrawingMode(.fillStroke)
    }
    draw(context, CGPoint(x: originX, y: originY))
    guard let data = context.data else { return .empty }
    texture.replace(
      region: MTLRegionMake2D(cursorX, cursorY, width, height),
      mipmapLevel: 0,
      withBytes: data,
      bytesPerRow: width * 4,
    )
    let entry = Entry(
      position: SIMD2(UInt16(cursorX), UInt16(cursorY)),
      size: SIMD2(UInt16(width), UInt16(height)),
      // Bitmap top-left relative to the cell's top-left.
      offset: SIMD2(offsetX, offsetY),
      isColor: isColor,
    )
    cursorX += width
    shelfHeight = max(shelfHeight, height)
    return entry
  }
}
