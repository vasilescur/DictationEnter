#!/usr/bin/env swift
// Generates AppIcon.icns from SF Symbols (mic.fill + return.left)
// matching the status bar icon used in Dictation Enter.

import Cocoa

let sizes: [(name: String, size: CGFloat)] = [
    ("icon_16x16",       16),
    ("icon_16x16@2x",    32),
    ("icon_32x32",       32),
    ("icon_32x32@2x",    64),
    ("icon_128x128",    128),
    ("icon_128x128@2x", 256),
    ("icon_256x256",    256),
    ("icon_256x256@2x", 512),
    ("icon_512x512",    512),
    ("icon_512x512@2x",1024),
]

func renderIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    // Background: rounded rectangle with gradient
    let bgRect = NSRect(x: 0, y: 0, width: size, height: size)
    let cornerRadius = size * 0.22
    let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: cornerRadius, yRadius: cornerRadius)

    // Dark gradient background
    let gradient = NSGradient(
        starting: NSColor(calibratedRed: 0.15, green: 0.15, blue: 0.20, alpha: 1.0),
        ending: NSColor(calibratedRed: 0.08, green: 0.08, blue: 0.12, alpha: 1.0)
    )!
    gradient.draw(in: bgPath, angle: 270)

    // Draw the SF Symbols in white
    let symbolPointSize = size * 0.30
    let config = NSImage.SymbolConfiguration(pointSize: symbolPointSize, weight: .medium)

    if let micImage = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let micSize = micImage.size
        // Position mic on the left-center area
        let micX = size * 0.18
        let micY = (size - micSize.height) / 2
        let tintedMic = tintImage(micImage, color: .white)
        tintedMic.draw(in: NSRect(x: micX, y: micY, width: micSize.width, height: micSize.height))
    }

    if let returnImage = NSImage(systemSymbolName: "return.left", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let returnSize = returnImage.size
        // Position return key on the right-center area
        let returnX = size * 0.52
        let returnY = (size - returnSize.height) / 2
        let tintedReturn = tintImage(returnImage, color: .white)
        tintedReturn.draw(in: NSRect(x: returnX, y: returnY, width: returnSize.width, height: returnSize.height))
    }

    image.unlockFocus()
    return image
}

func tintImage(_ image: NSImage, color: NSColor) -> NSImage {
    let tinted = NSImage(size: image.size)
    tinted.lockFocus()
    color.set()
    let rect = NSRect(origin: .zero, size: image.size)
    image.draw(in: rect, from: rect, operation: .sourceOver, fraction: 1.0)
    rect.fill(using: .sourceAtop)
    tinted.unlockFocus()
    return tinted
}

// Create iconset directory
let scriptDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let iconsetDir = scriptDir.appendingPathComponent("AppIcon.iconset")
let icnsPath = scriptDir.appendingPathComponent("AppIcon.icns")

// Remove old iconset if it exists
try? FileManager.default.removeItem(at: iconsetDir)
try FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

for entry in sizes {
    let icon = renderIcon(size: entry.size)
    guard let tiffData = icon.tiffRepresentation,
          let bitmapRep = NSBitmapImageRep(data: tiffData),
          let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
        print("Failed to create PNG for \(entry.name)")
        continue
    }
    let filePath = iconsetDir.appendingPathComponent("\(entry.name).png")
    try pngData.write(to: filePath)
    print("Created \(entry.name).png (\(Int(entry.size))x\(Int(entry.size)))")
}

// Convert iconset to icns
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetDir.path]
try process.run()
process.waitUntilExit()

if process.terminationStatus == 0 {
    print("Created AppIcon.icns successfully")
    // Clean up iconset
    try? FileManager.default.removeItem(at: iconsetDir)
} else {
    print("ERROR: iconutil failed with status \(process.terminationStatus)")
    exit(1)
}
