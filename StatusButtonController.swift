import Cocoa

final class StatusButtonController: NSObject {
    private weak var button: NSButton?
    private let click: () -> Void
    private let menu: () -> NSMenu
    private var pressTimer: Timer?
    private var handledLongPress = false
    private var downEvent: NSEvent?
    private var rightMonitor: Any?

    init(button: NSButton, click: @escaping () -> Void, menu: @escaping () -> NSMenu) {
        self.button = button; self.click = click; self.menu = menu
        super.init()
        button.target = self
        button.action = #selector(performAction)
        button.isContinuous = false
        button.sendAction(on: [.leftMouseDown, .leftMouseUp])
        rightMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard let self = self, let button = self.button, let window = button.window,
                  event.windowNumber == window.windowNumber,
                  button.bounds.contains(button.convert(event.locationInWindow, from: nil)) else { return event }
            self.pressTimer?.invalidate(); self.handledLongPress = true
            self.showMenu(event)
            return nil
        }
    }
    deinit {
        pressTimer?.invalidate()
        if let rightMonitor = rightMonitor { NSEvent.removeMonitor(rightMonitor) }
    }
    @objc private func performAction() {
        guard let event = NSApp.currentEvent else { click(); return }
        if CommandLine.arguments.contains("--trace-status") { print("STATUS_EVENT \(event.type.rawValue) pressed=\(NSEvent.pressedMouseButtons)"); fflush(stdout) }
        switch event.type {
        case .rightMouseUp:
            pressTimer?.invalidate(); handledLongPress = true
            showMenu(event)
        case .leftMouseDown:
            if downEvent?.timestamp == event.timestamp { return }
            pressTimer?.invalidate()
            handledLongPress = false
            downEvent = event
            if event.modifierFlags.contains(.control) {
                handledLongPress = true; showMenu(event); return
            }
            let timer = Timer(timeInterval: 0.45, repeats: false) { [weak self] _ in
                guard let self = self, let button = self.button,
                      self.downEvent != nil, !self.handledLongPress,
                      button.cell?.isHighlighted == true else { return }
                self.handledLongPress = true
                if CommandLine.arguments.contains("--trace-status") { print("STATUS_LONG"); fflush(stdout) }
                self.showMenu(self.downEvent)
            }
            pressTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        case .leftMouseUp:
            pressTimer?.invalidate(); pressTimer = nil; downEvent = nil
            if !handledLongPress { click() }
        default:
            break
        }
    }
    private func showMenu(_ event: NSEvent?) {
        guard let button = button else { return }
        let options = menu()
        if let event = event { NSMenu.popUpContextMenu(options, with: event, for: button) }
        else { options.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button) }
    }
}
