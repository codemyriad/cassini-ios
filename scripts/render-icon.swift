// Draws Cassini's app icon (the orbit mark on the dark ground, 1024 x 1024, opaque) into
// Cassini/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png. Run it from the repository root after changing
// the drawing: swift scripts/render-icon.swift
import AppKit
let size = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
NSColor(red: 0.075, green: 0.12, blue: 0.14, alpha: 1).setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: size, height: size)).fill()
NSColor(red: 1, green: 0.48, blue: 0.28, alpha: 1).setStroke()
let planet = NSBezierPath(ovalIn: NSRect(x: 290, y: 290, width: 444, height: 444))
planet.lineWidth = 32; planet.stroke()
let orbit = NSBezierPath(ovalIn: NSRect(x: -355, y: -112, width: 710, height: 224))
let transform = AffineTransform(translationByX: 512, byY: 512)
var rotation = AffineTransform(); rotation.rotate(byDegrees: 32)
orbit.transform(using: rotation); orbit.transform(using: transform)
orbit.lineWidth = 25; orbit.stroke()
NSColor(red: 1, green: 0.71, blue: 0.51, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: 737, y: 645, width: 80, height: 80)).fill()
image.unlockFocus()
let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
context.draw(image.cgImage(forProposedRect: nil, context: nil, hints: nil)!, in: CGRect(x: 0, y: 0, width: size, height: size))
let data = NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
try data.write(to: URL(fileURLWithPath: "Cassini/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"))
