#!/usr/bin/env swift
import AppKit

let scriptDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let sourceURL = scriptDirectory.appendingPathComponent("AppIconSource.jpg")
guard let source = NSImage(contentsOf: sourceURL) else {
    fputs("ERROR: cannot load generated icon source at \(sourceURL.path)\n", stderr)
    exit(1)
}

/// The selected source has a generous white border around an already polished tile.
/// Crop that border once, then render the same artwork deterministically at each size.
let sourceSize = source.size
let cropSide = min(sourceSize.width, sourceSize.height) * 0.84
let sourceCrop = NSRect(
    x: (sourceSize.width - cropSide) / 2,
    y: (sourceSize.height - cropSide) / 2,
    width: cropSide,
    height: cropSide
)

func renderIcon(size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: size, height: size).fill()

    let side = CGFloat(size)
    let destination = NSRect(x: side * 0.025, y: side * 0.025,
                             width: side * 0.95, height: side * 0.95)
    let mask = NSBezierPath(roundedRect: destination,
                            xRadius: side * 0.22, yRadius: side * 0.22)
    mask.addClip()
    source.draw(in: destination, from: sourceCrop, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func writePNG(size: Int, to url: URL) throws {
    let data = renderIcon(size: size).representation(using: .png, properties: [:])!
    try data.write(to: url, options: .atomic)
}

let assetDirectory = scriptDirectory
    .appendingPathComponent("Assets.xcassets/AppIcon.appiconset", isDirectory: true)
let iconsetDirectory = scriptDirectory
    .appendingPathComponent("TypeFlow.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: assetDirectory, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: iconsetDirectory, withIntermediateDirectories: true)

for size in [16, 32, 64, 128, 256, 512, 1024] {
    try writePNG(size: size, to: assetDirectory.appendingPathComponent("icon_\(size).png"))
}

let iconsetSizes: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (filename, size) in iconsetSizes {
    try writePNG(size: size, to: iconsetDirectory.appendingPathComponent(filename))
}

try writePNG(size: 512, to: scriptDirectory.appendingPathComponent("icon.png"))
print("Generated app icon assets from \(sourceURL.lastPathComponent)")
