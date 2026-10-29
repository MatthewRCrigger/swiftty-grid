// Generates the layered app icons that tvOS and visionOS require from
// icon.svg (the flat iOS/watchOS/macOS icon lives in
// Resources/Assets.xcassets):
//
//   Apps/TVClient/Assets.xcassets/App Icon & Top Shelf Image.brandassets
//     App Icon (400x240 @1x/@2x), App Icon - App Store (1280x768) and
//     Top Shelf Image (1920x720) / Wide (2320x720), @1x and @2x.
//   Apps/VisionClient/Assets.xcassets/AppIcon.solidimagestack
//     1024x1024 layers.
//
// usage: xcrun swift Scripts/gen-platform-icons.swift
//
// icon.svg is split into three parallax layers: Back (the background
// rects, rendered opaque), Middle (the window buttons) and Front (the
// prompt). Its viewBox is 824 units square; each canvas keeps that height
// and widens around the centre, and the background stretches to fill.
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0])
  .deletingLastPathComponent().deletingLastPathComponent()
let source = try String(
  contentsOf: root.appending(path: "icon.svg"),
  encoding: .utf8
)

func matches(_ pattern: String) throws -> [String] {
  let expression = try NSRegularExpression(
    pattern: pattern,
    options: [.dotMatchesLineSeparators]
  )
  let range = NSRange(source.startIndex..., in: source)
  return expression.matches(in: source, range: range)
    .map { String(source[Range($0.range, in: source)!]) }
}

let defs = try matches("<defs>.*?</defs>").first ?? ""
let rects = try matches("<rect [^>]*>(?:</rect>)?")
let circles = try matches("<circle [^>]*>(?:</circle>)?")
let paths = try matches("<path [^>]*>(?:</path>)?")
// The full-bleed rects are the background; the cursor rect is foreground.
let background = rects.filter { $0.contains("width=\"824\"") }
let cursor = rects.filter { !$0.contains("width=\"824\"") }
guard !background.isEmpty, circles.count == 3, paths.count == 1,
  cursor.count == 1
else {
  fatalError(
    "icon.svg no longer has the expected background, buttons, prompt and cursor"
  )
}

enum Layer: String, CaseIterable {
  case front = "Front"
  case middle = "Middle"
  case back = "Back"

  var elements: String {
    switch self {
    case .back: return defs + background.joined()
    case .middle: return circles.joined()
    case .front: return paths.joined() + cursor.joined()
    }
  }
}

/// Renders a layer onto a width x height canvas; the back layer has no
/// alpha channel because both platforms require an opaque background.
func png(_ layer: Layer?, width: Int, height: Int) -> Data {
  let unit = 824.0
  let viewWidth = unit * Double(width) / Double(height)
  let layers = layer.map { [$0] } ?? [.back, .middle, .front]
  let body =
    layers.map { layer in
      // The background stretches to the canvas; the artwork keeps its aspect.
      // (AppKit's SVG renderer ignores nested <svg> elements.)
      layer == .back
        ? "<g transform=\"scale(\(viewWidth / unit) 1) translate(-100 -100)\">\(layer.elements)</g>"
        : "<g transform=\"translate(\((viewWidth - unit) / 2 - 100) -100)\">\(layer.elements)</g>"
    }
    .joined()
  let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="\(width)" height="\(height)" \
    viewBox="0 0 \(viewWidth) \(unit)">\(body)</svg>
    """
  guard let image = NSImage(data: Data(svg.utf8)) else {
    fatalError("cannot render SVG")
  }
  let opaque = layer == nil || layer == .back
  let alpha: CGImageAlphaInfo = opaque ? .noneSkipLast : .premultipliedLast
  let context = CGContext(
    data: nil,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: alpha.rawValue
  )!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(
    cgContext: context,
    flipped: false
  )
  image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
  NSGraphicsContext.restoreGraphicsState()
  let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
  return bitmap.representation(using: .png, properties: [:])!
}

let info: [String: Any] = ["author": "xcode", "version": 1]

func write(
  _ directory: URL,
  contents: [String: Any],
  files: [String: Data] = [:]
) throws {
  try FileManager.default.createDirectory(
    at: directory,
    withIntermediateDirectories: true
  )
  var json = contents
  json["info"] = info
  let data = try JSONSerialization.data(
    withJSONObject: json,
    options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  )
  try (data + Data("\n".utf8))
    .write(to: directory.appending(path: "Contents.json"))
  for (name, data) in files {
    try data.write(to: directory.appending(path: name))
  }
}

/// An image set of `scales` renders of one layer (nil: all layers flattened).
func imageSet(
  _ directory: URL,
  layer: Layer?,
  idiom: String,
  width: Int,
  height: Int,
  scales: [Int]
) throws {
  var images: [[String: Any]] = []
  var files: [String: Data] = [:]
  for scale in scales {
    let name =
      "\((layer?.rawValue ?? "Image").lowercased())-\(width)x\(height)@\(scale)x.png"
    images.append(["filename": name, "idiom": idiom, "scale": "\(scale)x"])
    files[name] = png(layer, width: width * scale, height: height * scale)
  }
  try write(directory, contents: ["images": images], files: files)
}

func stack(
  _ directory: URL,
  kind: String,
  idiom: String,
  width: Int,
  height: Int,
  scales: [Int],
  pixelScale: Int = 1
) throws {
  try write(
    directory,
    contents: [
      "layers": Layer.allCases.map {
        ["filename": "\($0.rawValue).\(kind)layer"]
      }
    ]
  )
  for layer in Layer.allCases {
    let layerDirectory = directory.appending(
      path: "\(layer.rawValue).\(kind)layer"
    )
    try write(layerDirectory, contents: [:])
    try imageSet(
      layerDirectory.appending(path: "Content.imageset"),
      layer: layer,
      idiom: idiom,
      width: width / pixelScale,
      height: height / pixelScale,
      scales: scales
    )
  }
}

// tvOS
let tv = root.appending(path: "Apps/TVClient/Assets.xcassets")
try? FileManager.default.removeItem(at: tv)
try write(tv, contents: [:])
let brand = tv.appending(path: "App Icon & Top Shelf Image.brandassets")
try write(
  brand,
  contents: [
    "assets": [
      [
        "filename": "App Icon - App Store.imagestack", "idiom": "tv",
        "role": "primary-app-icon", "size": "1280x768",
      ],
      [
        "filename": "App Icon.imagestack", "idiom": "tv",
        "role": "primary-app-icon", "size": "400x240",
      ],
      [
        "filename": "Top Shelf Image Wide.imageset", "idiom": "tv",
        "role": "top-shelf-image-wide", "size": "2320x720",
      ],
      [
        "filename": "Top Shelf Image.imageset", "idiom": "tv",
        "role": "top-shelf-image", "size": "1920x720",
      ],
    ]
  ]
)
try stack(
  brand.appending(path: "App Icon - App Store.imagestack"),
  kind: "imagestack",
  idiom: "tv-marketing",
  width: 1280,
  height: 768,
  scales: [1]
)
try stack(
  brand.appending(path: "App Icon.imagestack"),
  kind: "imagestack",
  idiom: "tv",
  width: 400,
  height: 240,
  scales: [1, 2]
)
try imageSet(
  brand.appending(path: "Top Shelf Image.imageset"),
  layer: nil,
  idiom: "tv",
  width: 1920,
  height: 720,
  scales: [1, 2]
)
try imageSet(
  brand.appending(path: "Top Shelf Image Wide.imageset"),
  layer: nil,
  idiom: "tv",
  width: 2320,
  height: 720,
  scales: [1, 2]
)

// visionOS: 1024x1024 pixels per layer, catalogued at 2x.
let vision = root.appending(path: "Apps/VisionClient/Assets.xcassets")
try? FileManager.default.removeItem(at: vision)
try write(vision, contents: [:])
try stack(
  vision.appending(path: "AppIcon.solidimagestack"),
  kind: "solidimagestack",
  idiom: "vision",
  width: 1024,
  height: 1024,
  scales: [2],
  pixelScale: 2
)

print("wrote \(tv.path) and \(vision.path)")
