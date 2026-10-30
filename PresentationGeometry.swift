import Cocoa

func stablePixel(_ value: CGFloat) -> CGFloat {
    let rounded = value.rounded()
    return abs(value - rounded) < 0.02 ? rounded : value
}

func backingAligned(_ rect: CGRect, scale: CGFloat) -> CGRect {
    let scale = max(1, scale)
    let left = (rect.minX * scale).rounded() / scale
    let bottom = (rect.minY * scale).rounded() / scale
    let right = (rect.maxX * scale).rounded() / scale
    let top = (rect.maxY * scale).rounded() / scale
    return CGRect(x: left, y: bottom, width: right - left, height: top - bottom)
}

struct FrameGeometryStabilizer {
    private var previous: (pixels: CGSize, source: CGSize, rect: CGRect)?
    mutating func accept(_ frame: CapturedWindowFrame, sourceSize: CGSize) -> CapturedWindowFrame {
        let pixels = CGSize(width: frame.image.width, height: frame.image.height)
        var rectangle = frame.windowRect
        if let previous = previous, previous.pixels == pixels,
           abs(previous.source.width - sourceSize.width) < 0.001,
           abs(previous.source.height - sourceSize.height) < 0.001,
           abs(previous.rect.width - rectangle.width) < 0.1,
           abs(previous.rect.height - rectangle.height) < 0.1,
           abs(previous.rect.minX - rectangle.minX) <= 1,
           abs(previous.rect.minY - rectangle.minY) <= 1 {
            rectangle = previous.rect
        }
        previous = (pixels, sourceSize, rectangle)
        return CapturedWindowFrame(image: frame.image, windowRect: rectangle)
    }
}
