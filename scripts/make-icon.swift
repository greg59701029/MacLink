import AppKit
import Foundation

let size = 1024
let icon = NSImage(size: NSSize(width: size, height: size))
icon.lockFocus()

NSColor(calibratedRed: 0.035, green: 0.055, blue: 0.065, alpha: 1).setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: size, height: size)).fill()

let glow = NSBezierPath(ovalIn: NSRect(x: 115, y: 560, width: 320, height: 320))
NSColor(calibratedRed: 0.78, green: 0.96, blue: 0.40, alpha: 0.08).setFill()
glow.fill()

let screenRect = NSRect(x: 195, y: 304, width: 634, height: 440)
let screen = NSBezierPath(roundedRect: screenRect, xRadius: 52, yRadius: 52)
NSColor(calibratedRed: 0.08, green: 0.125, blue: 0.135, alpha: 1).setFill()
screen.fill()
NSColor(calibratedRed: 0.78, green: 0.96, blue: 0.40, alpha: 1).setStroke()
screen.lineWidth = 30
screen.stroke()

NSColor(calibratedRed: 0.78, green: 0.96, blue: 0.40, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 273, y: 645, width: 42, height: 42), xRadius: 18, yRadius: 18).fill()

NSColor(calibratedRed: 0.78, green: 0.96, blue: 0.40, alpha: 0.55).setStroke()
let lineOne = NSBezierPath()
lineOne.lineWidth = 18
lineOne.lineCapStyle = .round
lineOne.move(to: NSPoint(x: 352, y: 666))
lineOne.line(to: NSPoint(x: 628, y: 666))
lineOne.stroke()

let lineTwo = NSBezierPath()
lineTwo.lineWidth = 18
lineTwo.lineCapStyle = .round
lineTwo.move(to: NSPoint(x: 273, y: 575))
lineTwo.line(to: NSPoint(x: 552, y: 575))
lineTwo.stroke()

NSColor(calibratedRed: 0.78, green: 0.96, blue: 0.40, alpha: 1).setStroke()
let stem = NSBezierPath()
stem.lineWidth = 26
stem.lineCapStyle = .round
stem.move(to: NSPoint(x: 512, y: 282))
stem.line(to: NSPoint(x: 512, y: 202))
stem.stroke()

let foot = NSBezierPath()
foot.lineWidth = 28
foot.lineCapStyle = .round
foot.move(to: NSPoint(x: 365, y: 185))
foot.line(to: NSPoint(x: 659, y: 185))
foot.stroke()

icon.unlockFocus()
guard let tiff = icon.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Could not render app icon")
}
let destination = URL(fileURLWithPath: CommandLine.arguments[1])
try png.write(to: destination, options: .atomic)
