import Cocoa

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
func render(_ pixels: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    let background = NSBezierPath(roundedRect: NSRect(x: 58, y: 58, width: 908, height: 908), xRadius: 210, yRadius: 210)
    NSColor.white.setFill(); background.fill()
    NSColor.black.withAlphaComponent(0.06).setStroke(); background.lineWidth = 2; background.stroke()
    let config = NSImage.SymbolConfiguration(pointSize: 590, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.black]))
    let pin = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil)!.withSymbolConfiguration(config)!
    let available = NSRect(x: 260, y: 198, width: 504, height: 628)
    let fit = min(available.width / pin.size.width, available.height / pin.size.height)
    let size = NSSize(width: pin.size.width * fit, height: pin.size.height * fit)
    let rect = NSRect(x: available.midX - size.width / 2, y: available.midY - size.height / 2, width: size.width, height: size.height)
    pin.draw(in: rect)
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}
for side in [16, 32, 128, 256, 512] {
    try render(side).write(to: output.appendingPathComponent("icon_\(side)x\(side).png"))
    try render(side * 2).write(to: output.appendingPathComponent("icon_\(side)x\(side)@2x.png"))
}
