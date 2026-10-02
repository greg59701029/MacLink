import Foundation
import CoreGraphics
import CoreImage
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers

// Private stdout protocol: one status byte and a big-endian UInt32 size.
// 1 = JPEG, 2 = unchanged valid frame, 3 = unavailable. No files or sockets.
final class FrameOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let context = CIContext()
    private let lock = NSLock()
    private func emit(_ status: UInt8, _ data: Data = Data()) {
        lock.lock(); defer { lock.unlock() }
        var length = UInt32(data.count).bigEndian
        var packet = Data([status])
        withUnsafeBytes(of: &length) { packet.append(contentsOf: $0) }
        packet.append(data)
        FileHandle.standardOutput.write(packet)
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        emit(3)
        exit(1)
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, buffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { emit(3); return }
        if status == .idle { emit(2); return }
        guard status == .complete, let pixel = CMSampleBufferGetImageBuffer(buffer) else { emit(3); return }
        autoreleasepool {
            let image = CIImage(cvPixelBuffer: pixel)
            guard let cg = context.createCGImage(image, from: image.extent) else { emit(3); return }
            let data = NSMutableData()
            guard let output = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { emit(3); return }
            CGImageDestinationAddImage(output, cg, [kCGImageDestinationLossyCompressionQuality: 0.72] as CFDictionary)
            guard CGImageDestinationFinalize(output), data.length <= 12 * 1024 * 1024 else { emit(3); return }
            emit(1, data as Data)
        }
    }
}

@main struct ScreenStreamHelper {
    static func main() async {
        guard #available(macOS 14.0, *), CGPreflightScreenCaptureAccess() else {
            fputs("Screen capture permission or OS unavailable\n", stderr)
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
            let probe = FrameOutput()
            let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: configuration, delegate: probe)
            let queue = DispatchQueue(label: "MacLink.capture-stream")
            try stream.addStreamOutput(probe, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()
            // The parent closes the pipe or terminates us after inactivity.
            // Never emit diagnostics on stdout, which contains only framed data.
            while true {
                try await Task.sleep(for: .seconds(1))
                if CGMainDisplayID() != display.displayID { exit(1) }
            }
        } catch {
            fputs("Screen stream unavailable\n", stderr)
            exit(1)
        }
    }
}
