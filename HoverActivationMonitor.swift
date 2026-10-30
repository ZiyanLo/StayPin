import Cocoa

struct HoverEntryGate {
    private(set) var visible = false
    private var rectangle = CGRect.zero
    private var inside = false

    mutating func update(visible: Bool, rectangle: CGRect, pointer: CGPoint) {
        // A window appearing or moving beneath a stationary pointer must not
        // steal focus. Only a subsequent physical outside-to-inside entry acts.
        if visible != self.visible || rectangle != self.rectangle {
            inside = visible && rectangle.contains(pointer)
        }
        self.visible = visible; self.rectangle = rectangle
    }
    mutating func rebaseline(pointer: CGPoint) { inside = visible && rectangle.contains(pointer) }
    mutating func moved(to pointer: CGPoint) -> Bool {
        guard visible else { return false }
        let nowInside = rectangle.contains(pointer)
        let entered = nowInside && !inside
        inside = nowInside
        return entered
    }
}

final class HoverActivationMonitor {
    var enabled: Bool {
        didSet { gate.rebaseline(pointer: pointerLocation()) }
    }
    private var gate = HoverEntryGate()
    private var timer: Timer?
    private let activate: () -> Void
    private let canActivate: () -> Bool
    private let pointerLocation: () -> CGPoint

    init(enabled: Bool, pointerLocation: @escaping () -> CGPoint = { NSEvent.mouseLocation }, canActivate: @escaping () -> Bool = { true }, activate: @escaping () -> Void) {
        self.enabled = enabled; self.canActivate = canActivate; self.activate = activate
        self.pointerLocation = pointerLocation
        // Nonactivating panels do not reliably receive mouseMoved while another
        // application owns focus. Sampling the pointer also catches entry when
        // WindowServer coalesces or does not deliver movement events to us.
        let timer = Timer(timeInterval: 1.0 / 40.0, repeats: true) { [weak self] _ in self?.samplePointer() }
        timer.tolerance = 0.004
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    func update(visible: Bool, rectangle: CGRect) {
        gate.update(visible: visible, rectangle: rectangle, pointer: pointerLocation())
    }
    private func samplePointer() {
        guard enabled, gate.visible, NSEvent.pressedMouseButtons == 0 else { return }
        let entered = gate.moved(to: pointerLocation())
        if entered && canActivate() { activate() }
    }
    func stop() {
        timer?.invalidate(); timer = nil
    }
    deinit { stop() }
}

func topVisibleWindow(at point: CGPoint) -> CGWindowID? {
    // Use AppKit's actual hit testing, including transparent/click-through
    // windows and all screens; a rectangle-only CGWindow list is insufficient.
    let number = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
    return number > 0 ? CGWindowID(number) : nil
}
