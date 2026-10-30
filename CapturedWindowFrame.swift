import Cocoa
import CoreVideo
import ScreenCaptureKit

struct CapturedWindowFrame {
    let image: CGImage
    // Original window rectangle within the captured image, in top-left pixels.
    let windowRect: CGRect

    func presentationFrame(for source: CGRect) -> CGRect {
        let scaleX = source.width / windowRect.width
        let scaleY = source.height / windowRect.height
        return CGRect(x: source.minX - windowRect.minX * scaleX,
                      y: source.maxY + windowRect.minY * scaleY - CGFloat(image.height) * scaleY,
                      width: CGFloat(image.width) * scaleX,
                      height: CGFloat(image.height) * scaleY)
    }
}

func completeWindowFrame(image: CGImage, buffer: CVPixelBuffer, metadata: [SCStreamFrameInfo: Any]) -> CapturedWindowFrame {
    let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    guard #available(macOS 14, *),
          let body = nativeWindowImageRect(buffer: buffer, metadata: metadata),
          let dictionary = metadata[.boundingRect] as? [String: Any],
          let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
          let scale = metadata[.scaleFactor] as? Double, scale.isFinite, scale > 0 else {
        return CapturedWindowFrame(image: image, windowRect: imageBounds)
    }
    // Retain the full native shadow. Trim only unused output canvas, never the
    // source window's border or shadow at its actual rectangular frame.
    let rendered = CGRect(x: stablePixel(bounds.minX * scale), y: stablePixel(bounds.minY * scale),
                          width: stablePixel(bounds.width * scale), height: stablePixel(bounds.height * scale)).integral
    let fullFrame = rendered.intersection(imageBounds)
    guard !fullFrame.isEmpty, fullFrame.contains(body), let complete = image.cropping(to: fullFrame) else {
        return CapturedWindowFrame(image: image, windowRect: body)
    }
    return CapturedWindowFrame(image: complete,
                               windowRect: body.offsetBy(dx: -fullFrame.minX, dy: -fullFrame.minY))
}
