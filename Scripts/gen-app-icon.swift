#!/usr/bin/env swift
// Draws the GRID app icon into Resources/Assets.xcassets/AppIcon.appiconset:
// a true-black field, the double frame, a near-white prompt chevron and an
// amber block cursor. Flat, no gradient, no glow.
//
// usage: swift Scripts/gen-app-icon.swift
import AppKit

let out = "Resources/Assets.xcassets/AppIcon.appiconset"
let ink = NSColor(srgbRed: 0xe4 / 255, green: 0xf2 / 255, blue: 0xf8 / 255, alpha: 1)
let line100 = NSColor(srgbRed: 0xd6 / 255, green: 0xea / 255, blue: 0xf2 / 255, alpha: 1)
let line300 = NSColor(srgbRed: 0x4a / 255, green: 0x5a / 255, blue: 0x63 / 255, alpha: 1)
let amber = NSColor(srgbRed: 0xf4 / 255, green: 0xbe / 255, blue: 0x4f / 255, alpha: 1)

/// Draws the artwork into a 1024-point square. `body` is the icon shape:
/// the full square for iOS (the system masks it) or the inset macOS tile.
func draw(body: NSRect, radius: CGFloat) {
  NSColor.black.setFill()
  NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius).fill()
  let s = body.width / 1024
  func at(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
    NSPoint(x: body.minX + x * s, y: body.minY + y * s)
  }
  // Double frame: outer line-100, a gap of void, inner line-300.
  for (inset, width, color) in [(78.0, 10.0, line100), (118.0, 6.0, line300)] {
    let r = body.insetBy(dx: inset * s, dy: inset * s)
    let p = NSBezierPath(roundedRect: r, xRadius: 28 * s, yRadius: 28 * s)
    p.lineWidth = width * s
    color.setStroke()
    p.stroke()
  }
  // Prompt chevron.
  let chevron = NSBezierPath()
  chevron.move(to: at(300, 380))
  chevron.line(to: at(450, 512))
  chevron.line(to: at(300, 644))
  chevron.lineWidth = 46 * s
  chevron.lineCapStyle = .square
  chevron.lineJoinStyle = .miter
  ink.setStroke()
  chevron.stroke()
  // Block cursor.
  amber.setFill()
  NSBezierPath(rect: NSRect(x: body.minX + 520 * s, y: body.minY + 372 * s,
                            width: 190 * s, height: 62 * s)).fill()
}

func render(pixels: Int, mac: Bool) -> Data {
  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  let ctx = NSGraphicsContext(bitmapImageRep: rep)!
  NSGraphicsContext.current = ctx
  ctx.imageInterpolation = .high
  let t = NSAffineTransform()
  t.scale(by: CGFloat(pixels) / 1024)
  t.concat()
  NSColor.clear.setFill()
  NSRect(x: 0, y: 0, width: 1024, height: 1024).fill()
  if mac {
    draw(body: NSRect(x: 100, y: 100, width: 824, height: 824), radius: 185)
  } else {
    draw(body: NSRect(x: 0, y: 0, width: 1024, height: 1024), radius: 0)
  }
  NSGraphicsContext.restoreGraphicsState()
  return rep.representation(using: .png, properties: [:])!
}

try render(pixels: 1024, mac: false)
  .write(to: URL(fileURLWithPath: "\(out)/AppIcon-1024.png"))
for size in [16, 32, 128, 256, 512] {
  for scale in [1, 2] {
    try render(pixels: size * scale, mac: true)
      .write(to: URL(fileURLWithPath: "\(out)/mac-\(size)x\(size)-\(scale)x.png"))
  }
}
print("wrote \(out)")
