import CoreGraphics
import Foundation
import ApplicationServices
import AppKit

let args = CommandLine.arguments
let source = CGEventSource(stateID: .hidSystemState)

guard args.count >= 2 else {
    fputs("Invalid input command\n", stderr)
    exit(2)
}

switch args[1] {
case "accessibility_status":
    guard args.count == 2 else { exit(2) }
    print(AXIsProcessTrusted() ? "granted" : "denied")
case "cursor_position":
    guard args.count == 2, let event = CGEvent(source: nil) else { exit(2) }
    let point = event.location
    print("\(Int(point.x)),\(Int(point.y))")
case "type":
    guard args.count == 3, !args[2].isEmpty else { exit(2) }
    let clipboard = NSPasteboard.general
    var saved: [NSPasteboardItem] = []
    for original in clipboard.pasteboardItems ?? [] {
        let copy = NSPasteboardItem()
        for kind in original.types {
            guard let data = original.data(forType: kind) else {
                fputs("Could not preserve clipboard data\n", stderr)
                exit(1)
            }
            copy.setData(data, forType: kind)
        }
        saved.append(copy)
    }
    clipboard.clearContents()
    guard clipboard.setString(args[2], forType: .string) else { exit(1) }
    let ownChange = clipboard.changeCount
    defer {
        if clipboard.changeCount == ownChange {
            clipboard.clearContents()
            if !saved.isEmpty { _ = clipboard.writeObjects(saved) }
        }
    }
    guard let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { exit(1) }
    down.flags = .maskCommand
    up.flags = .maskCommand
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.35)
case "display_info":
    guard args.count == 2 else { exit(2) }
    let display = CGMainDisplayID()
    let bounds = CGDisplayBounds(display)
    guard bounds.width > 0, bounds.height > 0 else { exit(1) }
    print("\(display),\(Int(bounds.width)),\(Int(bounds.height))")
case "click", "double_click":
    guard args.count == 4, let x = Double(args[2]), let y = Double(args[3]),
          x.isFinite, y.isFinite else {
        fputs("Invalid click position\n", stderr)
        exit(2)
    }
    let point = CGPoint(x: x, y: y)
    let count: Int64 = args[1] == "double_click" ? 2 : 1
    for click in 1...count {
        guard let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                                 mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                               mouseCursorPosition: point, mouseButton: .left) else {
            fputs("Could not create click event\n", stderr)
            exit(1)
        }
        down.setIntegerValueField(.mouseEventClickState, value: click)
        up.setIntegerValueField(.mouseEventClickState, value: click)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        if click == 1 && count == 2 { Thread.sleep(forTimeInterval: 0.08) }
    }
case "scroll":
    guard args.count == 3, let amount = Int32(args[2]), (-1200...1200).contains(amount) else {
        fputs("Invalid scroll amount\n", stderr)
        exit(2)
    }
    guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1,
                              wheel1: amount, wheel2: 0, wheel3: 0) else {
        fputs("Could not create scroll event\n", stderr)
        exit(1)
    }
    event.post(tap: .cghidEventTap)
case "right_click":
    guard args.count == 4, let x = Double(args[2]), let y = Double(args[3]),
          x.isFinite, y.isFinite else {
        fputs("Invalid click position\n", stderr)
        exit(2)
    }
    let point = CGPoint(x: x, y: y)
    guard let down = CGEvent(mouseEventSource: source, mouseType: .rightMouseDown,
                             mouseCursorPosition: point, mouseButton: .right),
          let up = CGEvent(mouseEventSource: source, mouseType: .rightMouseUp,
                           mouseCursorPosition: point, mouseButton: .right) else {
        fputs("Could not create mouse event\n", stderr)
        exit(1)
    }
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
case "drag":
    guard args.count == 6,
          let x1 = Double(args[2]), let y1 = Double(args[3]),
          let x2 = Double(args[4]), let y2 = Double(args[5]),
          [x1, y1, x2, y2].allSatisfy(\.isFinite) else {
        fputs("Invalid drag positions\n", stderr)
        exit(2)
    }
    let start = CGPoint(x: x1, y: y1)
    let end = CGPoint(x: x2, y: y2)
    guard let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                             mouseCursorPosition: start, mouseButton: .left),
          let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                           mouseCursorPosition: end, mouseButton: .left) else {
        fputs("Could not create drag events\n", stderr)
        exit(1)
    }
    down.post(tap: .cghidEventTap)
    for step in 1...14 {
        let fraction = CGFloat(step) / 14
        let point = CGPoint(x: start.x + (end.x - start.x) * fraction,
                            y: start.y + (end.y - start.y) * fraction)
        if let dragged = CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged,
                                 mouseCursorPosition: point, mouseButton: .left) {
            dragged.post(tap: .cghidEventTap)
        }
        Thread.sleep(forTimeInterval: 0.012)
    }
    up.post(tap: .cghidEventTap)
case "trash":
    guard args.count == 3 else {
        fputs("Invalid trash path\n", stderr)
        exit(2)
    }
    do {
        try FileManager.default.trashItem(at: URL(fileURLWithPath: args[2]), resultingItemURL: nil)
    } catch {
        fputs("Could not move item to Trash: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
default:
    fputs("Unknown input command\n", stderr)
    exit(2)
}
