import Cocoa
import ScreenCaptureKit
import CoreVideo

// Capture the native rim instead of suppressing window framing. Locate the
// original rectangle inside the shadow image without assuming fixed shadow
// insets; their geometry changes with focus, OS version, and capture scale.
func nativeWindowImageRect(buffer: CVPixelBuffer, metadata: [SCStreamFrameInfo: Any]) -> CGRect? {
    guard #available(macOS 14, *) else { return nil }
    func rectangle(_ key: SCStreamFrameInfo) -> CGRect? {
        guard let dictionary = metadata[key] as? [String: Any] else { return nil }
        return CGRect(dictionaryRepresentation: dictionary as CFDictionary)
    }
    guard let screen = rectangle(.screenRect), let bounding = rectangle(.boundingRect),
          let displayScale = metadata[.scaleFactor] as? Double,
          let contentScale = metadata[.contentScale] as? Double,
          displayScale.isFinite, contentScale.isFinite,
          displayScale > 0, contentScale > 0 else { return nil }
    let pixelsWide = CVPixelBufferGetWidth(buffer), pixelsHigh = CVPixelBufferGetHeight(buffer)
    let scale = displayScale * contentScale
    let width = stablePixel(screen.width * scale), height = stablePixel(screen.height * scale)
    let box = CGRect(x: bounding.minX * displayScale, y: bounding.minY * displayScale,
                     width: bounding.width * displayScale, height: bounding.height * displayScale)
    guard width.isFinite, height.isFinite, box.minX.isFinite, box.minY.isFinite,
          width > 0, height > 0, width <= CGFloat(pixelsWide), height <= CGFloat(pixelsHigh),
          box.width.isFinite, box.height.isFinite else { return nil }
    let x = max(0, floor(box.minX + (box.width - width) / 2))
    let column = min(pixelsWide - 1, max(0, Int(box.midX)))
    let firstRow = min(pixelsHigh - 1, max(0, Int(floor(box.minY))))
    let lastRow = min(pixelsHigh - 1, max(firstRow, Int(ceil(box.maxY - height))))
    var top = max(0, floor(box.minY + (box.height - height) / 2))
    guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return nil }
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    if let address = CVPixelBufferGetBaseAddress(buffer) {
        let bytes = address.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        var peak: UInt8 = 0
        for row in firstRow...lastRow { peak = max(peak, bytes[row * stride + column * 4 + 3]) }
        if peak >= 8 {
            let threshold = max(8, Int(peak) * 95 / 100)
            if let edge = (firstRow...lastRow).first(where: { Int(bytes[$0 * stride + column * 4 + 3]) >= threshold }) {
                top = CGFloat(max(firstRow, edge - 1))
            }
        }
    }
    let rect = CGRect(x: x, y: top, width: ceil(stablePixel(width)), height: ceil(stablePixel(height)))
    guard CGRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh).contains(rect) else { return nil }
    return rect
}
