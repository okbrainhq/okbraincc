#!/usr/bin/env swift
import AppKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
  FileHandle.standardError.write(Data("usage: generate_app_icon.swift <output.icns> [sf-symbol]\n".utf8))
  exit(2)
}

let outputURL = URL(fileURLWithPath: arguments[1])
let symbolName = arguments.count >= 3 ? arguments[2] : "brain.head.profile"
let fileManager = FileManager.default
let iconsetURL = outputURL.deletingPathExtension().appendingPathExtension("iconset")

try? fileManager.removeItem(at: iconsetURL)
try? fileManager.removeItem(at: outputURL)
try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let sizes: [(filename: String, pixels: CGFloat)] = [
  ("icon_16x16.png", 16),
  ("icon_16x16@2x.png", 32),
  ("icon_32x32.png", 32),
  ("icon_32x32@2x.png", 64),
  ("icon_128x128.png", 128),
  ("icon_128x128@2x.png", 256),
  ("icon_256x256.png", 256),
  ("icon_256x256@2x.png", 512),
  ("icon_512x512.png", 512),
  ("icon_512x512@2x.png", 1024)
]

func drawIcon(size pixels: CGFloat) throws -> NSImage {
  guard let baseSymbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else {
    throw NSError(domain: "OkBrainCCIcon", code: 1, userInfo: [
      NSLocalizedDescriptionKey: "Unable to load SF Symbol: \(symbolName)"
    ])
  }

  let image = NSImage(size: NSSize(width: pixels, height: pixels))
  image.lockFocus()
  defer { image.unlockFocus() }

  let rect = NSRect(x: 0, y: 0, width: pixels, height: pixels)
  NSColor(red: 0.10, green: 0.12, blue: 0.13, alpha: 1).setFill()
  NSBezierPath(roundedRect: rect, xRadius: pixels * 0.22, yRadius: pixels * 0.22).fill()

  let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: pixels * 0.58, weight: .regular)
    .applying(NSImage.SymbolConfiguration(hierarchicalColor: .white))
  let symbol = baseSymbol.withSymbolConfiguration(symbolConfiguration) ?? baseSymbol
  symbol.isTemplate = false

  let maxSymbolSize = pixels * 0.62
  let aspectRatio = symbol.size.width / max(symbol.size.height, 1)
  let symbolSize: NSSize
  if aspectRatio >= 1 {
    symbolSize = NSSize(width: maxSymbolSize, height: maxSymbolSize / aspectRatio)
  } else {
    symbolSize = NSSize(width: maxSymbolSize * aspectRatio, height: maxSymbolSize)
  }

  let symbolRect = NSRect(
    x: (pixels - symbolSize.width) / 2,
    y: (pixels - symbolSize.height) / 2,
    width: symbolSize.width,
    height: symbolSize.height
  )
  symbol.draw(in: symbolRect, from: .zero, operation: .sourceOver, fraction: 1)

  return image
}

func writePNG(_ image: NSImage, to url: URL) throws {
  guard
    let tiffData = image.tiffRepresentation,
    let bitmap = NSBitmapImageRep(data: tiffData),
    let pngData = bitmap.representation(using: .png, properties: [:])
  else {
    throw NSError(domain: "OkBrainCCIcon", code: 2, userInfo: [
      NSLocalizedDescriptionKey: "Unable to encode icon PNG"
    ])
  }

  try pngData.write(to: url, options: .atomic)
}

for size in sizes {
  let image = try drawIcon(size: size.pixels)
  try writePNG(image, to: iconsetURL.appendingPathComponent(size.filename))
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetURL.path, "-o", outputURL.path]
try process.run()
process.waitUntilExit()

if process.terminationStatus != 0 {
  throw NSError(domain: "OkBrainCCIcon", code: Int(process.terminationStatus), userInfo: [
    NSLocalizedDescriptionKey: "iconutil failed"
  ])
}

try? fileManager.removeItem(at: iconsetURL)
