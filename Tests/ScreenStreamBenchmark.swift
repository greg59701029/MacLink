import Foundation
import CoreGraphics
import CoreImage
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers

final class FrameProbe: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let context = CIContext()
    private let started = ProcessInfo.processInfo.systemUptime
    private var frames = 0
    private var idle = 0
    private var firstMs: Double?
    private var arrivals: [Double] = []
    private var encodingMs: [Double] = []
    private var jpegBytes: [Int] = []
    private var lastBytes = 0
    private var failed = false
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock(); failed = true; lock.unlock()
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, buffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return }
        if status == .idle { lock.lock(); idle += 1; lock.unlock(); return }
        guard status == .complete, let pixel = CMSampleBufferGetImageBuffer(buffer) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let image = CIImage(cvPixelBuffer: pixel)
        guard let cg = context.createCGImage(image, from: image.extent) else { return }
        let data = NSMutableData()
        guard let output = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(output, cg, [kCGImageDestinationLossyCompressionQuality: 0.72] as CFDictionary)
        guard CGImageDestinationFinalize(output) else { return }
        let finished = ProcessInfo.processInfo.systemUptime
        lock.lock()
        frames += 1
        if firstMs == nil { firstMs = (finished - started) * 1000 }
        arrivals.append((now - started) * 1000)
        encodingMs.append((finished - now) * 1000)
        lastBytes = data.length
        jpegBytes.append(data.length)
        lock.unlock()
    }
    func report() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        let sortedBytes = jpegBytes.sorted()
        let medianBytes = sortedBytes.isEmpty ? 0 : sortedBytes[sortedBytes.count / 2]
        let meanBytes = sortedBytes.isEmpty ? 0 : sortedBytes.reduce(0, +) / sortedBytes.count
        let intervals = zip(arrivals.dropFirst(), arrivals).map { $0 - $1 }
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return 0 }
            let middle = sorted.count / 2
            return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
        }
        return ["complete_frames": frames, "idle_callbacks": idle, "first_jpeg_ms": firstMs ?? -1,
                "arrival_ms": arrivals, "encoding_ms": encodingMs, "last_jpeg_bytes": lastBytes,
                "median_jpeg_bytes": medianBytes, "mean_jpeg_bytes": meanBytes,
                "median_frame_interval_ms": median(intervals), "median_encode_ms": median(encodingMs),
                "stream_failed": failed, "images_saved": false]
    }
}

@main struct ScreenStreamBenchmark {
    static func main() async {
        guard #available(macOS 14.0, *), CGPreflightScreenCaptureAccess() else {
            print("Existing screen permission and macOS 14 required; no prompt requested")
            exit(77)
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else { exit(2) }
            let configuration = SCStreamConfiguration()
            configuration.width = max(1, display.width)
            configuration.height = max(1, display.height)
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            configuration.queueDepth = 4
            configuration.showsCursor = false
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            let probe = FrameProbe()
            let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: configuration, delegate: probe)
            let queue = DispatchQueue(label: "MacLink.capture-benchmark")
            try stream.addStreamOutput(probe, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()
            try await Task.sleep(for: .seconds(8))
            try await stream.stopCapture()
            queue.sync {}
            var report = probe.report()
            report["duration_seconds"] = 8
            report["configured_max_fps"] = 30
            report["width"] = configuration.width
            report["height"] = configuration.height
            let json = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            print(String(decoding: json, as: UTF8.self))
        } catch {
            print("Stream benchmark failed: \(type(of: error))")
            exit(1)
        }
    }
}
