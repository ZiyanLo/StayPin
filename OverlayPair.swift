import Cocoa

// Separate windows keep the genuine shadow visible without turning its
// transparent margins into a mouse-interception area.
final class OverlayPair {
    let visual: NSPanel
    let input: NSPanel
    var isVisible: Bool { visual.isVisible && input.isVisible }

    init(sourceFrame: CGRect, visualView: NSView, inputView: NSView) {
        let style: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]
        visual = NSPanel(contentRect: sourceFrame, styleMask: style, backing: .buffered, defer: false)
        input = NSPanel(contentRect: sourceFrame, styleMask: style, backing: .buffered, defer: false)
        configureFloatingOverlay(visual)
        configureFloatingOverlay(input)
        visual.ignoresMouseEvents = true
        input.ignoresMouseEvents = false
        visual.contentView = visualView
        input.contentView = inputView
    }
    func setFrames(source: CGRect, presentation: CGRect) {
        let scale = visual.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let source = backingAligned(source, scale: scale)
        let presentation = backingAligned(presentation, scale: scale)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if visual.frame != presentation { visual.setFrame(presentation, display: false) }
        if input.frame != source { input.setFrame(source, display: false) }
        visual.contentView?.layoutSubtreeIfNeeded()
        input.contentView?.layoutSubtreeIfNeeded()
        CATransaction.commit()
    }
    func present(_ frame: CapturedWindowFrame, source: CGRect, layer: CALayer) {
        // Geometry and image enter the same Core Animation transaction. Do not
        // display a new shadow canvas against the previous polling tick's frame.
        CATransaction.begin(); CATransaction.setDisableActions(true)
        setFrames(source: source, presentation: frame.presentationFrame(for: source))
        layer.frame = visual.contentView?.bounds ?? .zero
        layer.contents = frame.image
        CATransaction.commit()
    }
    func show() {
        visual.orderFrontRegardless()
        input.orderFrontRegardless()
    }
    func orderOut(_ sender: Any?) { input.orderOut(sender); visual.orderOut(sender) }
    func close() { input.close(); visual.close() }
}
