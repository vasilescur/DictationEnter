#!/usr/bin/env swift
import Cocoa

let width: CGFloat = 660
let height: CGFloat = 400
let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "dmg_background.png"

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(width * 2),
    pixelsHigh: Int(height * 2),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
)!
rep.size = NSSize(width: width, height: height)

NSGraphicsContext.saveGraphicsState()
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = ctx

// White background
NSColor.white.setFill()
NSRect(x: 0, y: 0, width: width, height: height).fill()

// Arrow from left area to right area
let arrowY: CGFloat = height * 0.48
let arrowStartX: CGFloat = width * 0.35
let arrowEndX: CGFloat = width * 0.65
let arrowHeadSize: CGFloat = 16

// Arrow shaft
let arrowPath = NSBezierPath()
arrowPath.lineWidth = 2.5
arrowPath.lineCapStyle = .round

// Dashed line
let dashPattern: [CGFloat] = [8, 6]
arrowPath.setLineDash(dashPattern, count: 2, phase: 0)

arrowPath.move(to: NSPoint(x: arrowStartX, y: arrowY))
arrowPath.line(to: NSPoint(x: arrowEndX - arrowHeadSize, y: arrowY))

NSColor(white: 0.0, alpha: 0.25).setStroke()
arrowPath.stroke()

// Arrow head (solid, not dashed)
let headPath = NSBezierPath()
headPath.lineWidth = 2.5
headPath.lineCapStyle = .round
headPath.lineJoinStyle = .round
headPath.move(to: NSPoint(x: arrowEndX - arrowHeadSize, y: arrowY + arrowHeadSize * 0.6))
headPath.line(to: NSPoint(x: arrowEndX, y: arrowY))
headPath.line(to: NSPoint(x: arrowEndX - arrowHeadSize, y: arrowY - arrowHeadSize * 0.6))
headPath.stroke()

// "Install" text
let installAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 13, weight: .medium),
    .foregroundColor: NSColor(white: 0.0, alpha: 0.3),
]
let installText = "Drag to install" as NSString
let installSize = installText.size(withAttributes: installAttrs)
installText.draw(
    at: NSPoint(x: (width - installSize.width) / 2, y: arrowY - 28),
    withAttributes: installAttrs
)

// Title at top - serif font
let serifFont = NSFont(name: "Georgia", size: 30) ?? NSFont.systemFont(ofSize: 30, weight: .light)
let titleAttrs: [NSAttributedString.Key: Any] = [
    .font: serifFont,
    .foregroundColor: NSColor(white: 0.0, alpha: 0.85),
]
let titleText = "Install Dictation Enter" as NSString
let titleSize = titleText.size(withAttributes: titleAttrs)
titleText.draw(
    at: NSPoint(x: (width - titleSize.width) / 2, y: height - 60),
    withAttributes: titleAttrs
)

// Tagline below title
let taglineAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 15, weight: .regular),
    .foregroundColor: NSColor(white: 0.0, alpha: 0.45),
]
let taglineText = "Automatically presses Enter for you when you\u{2019}re done dictating." as NSString
let taglineSize = taglineText.size(withAttributes: taglineAttrs)
taglineText.draw(
    at: NSPoint(x: (width - taglineSize.width) / 2, y: height - 86),
    withAttributes: taglineAttrs
)

// Subtle bottom line
let linePath = NSBezierPath()
linePath.move(to: NSPoint(x: width * 0.2, y: 30))
linePath.line(to: NSPoint(x: width * 0.8, y: 30))
linePath.lineWidth = 0.5
NSColor(white: 0.0, alpha: 0.06).setStroke()
linePath.stroke()

NSGraphicsContext.restoreGraphicsState()

// Save as PNG
let pngData = rep.representation(using: .png, properties: [:])!
let url = URL(fileURLWithPath: outputPath)
try! pngData.write(to: url)
print("Generated DMG background: \(outputPath)")
