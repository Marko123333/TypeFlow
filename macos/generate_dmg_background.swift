#!/usr/bin/env swift
import AppKit
import CoreGraphics

let width: CGFloat = 900
let height: CGFloat = 480

func readVersion() -> String {
    let path = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("version.json").path
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let version = json["version"] as? String else { return "?" }
    return version
}

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(width),
    pixelsHigh: Int(height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
)!

NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

let background = CGGradient(
    colorsSpace: colorSpace,
    colors: [
        NSColor(calibratedRed: 0.985, green: 0.995, blue: 1.00, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.925, green: 0.975, blue: 0.995, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.955, green: 1.00, blue: 0.975, alpha: 1).cgColor,
    ] as CFArray,
    locations: [0, 0.56, 1]
)!
ctx.drawLinearGradient(
    background,
    start: CGPoint(x: 0, y: height),
    end: CGPoint(x: width, y: 0),
    options: []
)

func fillCircle(center: CGPoint, radius: CGFloat, color: NSColor) {
    ctx.setFillColor(color.cgColor)
    ctx.fillEllipse(in: CGRect(
        x: center.x - radius,
        y: center.y - radius,
        width: radius * 2,
        height: radius * 2
    ))
}

fillCircle(
    center: CGPoint(x: 90, y: 392),
    radius: 155,
    color: NSColor(calibratedRed: 0.47, green: 0.84, blue: 1, alpha: 0.08)
)
fillCircle(
    center: CGPoint(x: 828, y: 378),
    radius: 180,
    color: NSColor(calibratedRed: 0.46, green: 1, blue: 0.80, alpha: 0.07)
)

let titleAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 32, weight: .semibold),
    .foregroundColor: NSColor(calibratedRed: 0.08, green: 0.16, blue: 0.22, alpha: 1),
]
let title = "Установка TypeFlow" as NSString
let titleSize = title.size(withAttributes: titleAttributes)
title.draw(at: CGPoint(x: (width - titleSize.width) / 2, y: 421), withAttributes: titleAttributes)

let subtitleAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 13, weight: .medium),
    .foregroundColor: NSColor(calibratedRed: 0.31, green: 0.42, blue: 0.49, alpha: 1),
]
let subtitle = "Два понятных шага - и приложение готово к работе" as NSString
let subtitleSize = subtitle.size(withAttributes: subtitleAttributes)
subtitle.draw(at: CGPoint(x: (width - subtitleSize.width) / 2, y: 395), withAttributes: subtitleAttributes)

func drawArrow(from startX: CGFloat, to endX: CGFloat, y: CGFloat) {
    let color = NSColor(calibratedRed: 0.16, green: 0.62, blue: 0.84, alpha: 0.86)
    ctx.setStrokeColor(color.cgColor)
    ctx.setLineWidth(3.5)
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: startX, y: y))
    ctx.addLine(to: CGPoint(x: endX - 13, y: y))
    ctx.strokePath()
    ctx.setFillColor(color.cgColor)
    ctx.move(to: CGPoint(x: endX, y: y))
    ctx.addLine(to: CGPoint(x: endX - 17, y: y + 11))
    ctx.addLine(to: CGPoint(x: endX - 17, y: y - 11))
    ctx.closePath()
    ctx.fillPath()
}

drawArrow(from: 392, to: 508, y: 243)

let stepAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
    .foregroundColor: NSColor(calibratedRed: 0.12, green: 0.47, blue: 0.65, alpha: 1),
    .kern: 0.6,
]
let stepOne = "1. ПЕРЕТАЩИТЕ" as NSString
let stepTwo = "2. ОТКРОЙТЕ" as NSString
stepOne.draw(at: CGPoint(x: 401, y: 263), withAttributes: stepAttributes)
stepTwo.draw(at: CGPoint(x: 592, y: 326), withAttributes: stepAttributes)

let cardRect = CGRect(x: 45, y: 32, width: width - 90, height: 106)
let cardPath = NSBezierPath(roundedRect: cardRect, xRadius: 19, yRadius: 19)
NSColor(calibratedWhite: 1, alpha: 0.89).setFill()
cardPath.fill()
NSColor(calibratedRed: 0.68, green: 0.85, blue: 0.91, alpha: 0.72).setStroke()
cardPath.lineWidth = 1
cardPath.stroke()

let instructionAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 14, weight: .medium),
    .foregroundColor: NSColor(calibratedRed: 0.09, green: 0.18, blue: 0.23, alpha: 1),
]
let mutedAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 11.5, weight: .regular),
    .foregroundColor: NSColor(calibratedRed: 0.34, green: 0.44, blue: 0.50, alpha: 1),
]
("1. Перетащите TypeFlow в Applications" as NSString)
    .draw(at: CGPoint(x: 70, y: 102), withAttributes: instructionAttributes)
("2. Дважды нажмите Applications, затем откройте TypeFlow" as NSString)
    .draw(at: CGPoint(x: 70, y: 76), withAttributes: instructionAttributes)
("Если macOS заблокирует: Системные настройки > Конфиденциальность и безопасность > «Все равно открыть»" as NSString)
    .draw(at: CGPoint(x: 70, y: 50), withAttributes: mutedAttributes)

let version = "v\(readVersion())  ·  macOS 13+  ·  Apple Silicon" as NSString
let versionSize = version.size(withAttributes: mutedAttributes)
version.draw(at: CGPoint(x: width - versionSize.width - 18, y: 456), withAttributes: mutedAttributes)

NSGraphicsContext.current = nil
let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "dmg_background.png"
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outputPath))
print("Generated: \(outputPath) (\(Int(width))x\(Int(height)))")
