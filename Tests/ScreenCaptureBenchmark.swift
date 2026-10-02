import Foundation
import CoreGraphics
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers

// Isolated benchmark: no permission prompt, no network, no saved screenshots.
@main struct ScreenCaptureBenchmark {
    static func main() async {
        guard #available(macOS 14.0, *) else {
            print("Requires macOS 14 or later")
            exit(2)
        }
        guard CGPreflightScreenCaptureAccess() else {
            print("Screen capture permission is unavailable for this process; no prompt requested")
            exit(77)
        }
        do {
            let discoveryStart = ContinuousClock.now
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else {
                throw NSError(domain: "MacLinkBenchmark", code: 1)
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let configuration = SCStreamConfiguration()
            let scale = min(1.0, 1600.0 / Double(max(display.width, display.height)))
            configuration.width = max(1, Int(Double(display.width) * scale))
            configuration.height = max(1, Int(Double(display.height) * scale))
            configuration.showsCursor = false
            let setupMs = milliseconds(discoveryStart.duration(to: .now))
            var durations: [Double] = []
            var sizes: [Int] = []
            for _ in 0..<12 {
                let start = ContinuousClock.now
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                let data = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
                    throw NSError(domain: "MacLinkBenchmark", code: 2)
                }
                CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.5] as CFDictionary)
                guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "MacLinkBenchmark", code: 3) }
                durations.append(milliseconds(start.duration(to: .now)))
                sizes.append(data.length)
                try await Task.sleep(for: .milliseconds(100))
            }
            let report: [String: Any] = ["backend": "ScreenCaptureKit SCScreenshotManager", "setup_ms": setupMs, "samples_ms": durations, "jpeg_bytes": sizes, "width": configuration.width, "height": configuration.height, "images_saved": false]
            let json = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            print(String(decoding: json, as: UTF8.self))
        } catch {
            print("Capture benchmark failed: \(type(of: error))")
            exit(1)
        }
    }
    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
}
