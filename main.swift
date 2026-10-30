import Cocoa
import Carbon
import ApplicationServices
import ScreenCaptureKit
import AVFoundation
import CoreImage

// Independently implemented live-overlay / original-window handoff.
// No input interception, event injection, disk recording, or network requests.
final class MirrorView: NSView {
    let video = CALayer()
    var handoff: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        video.isOpaque = false
        video.backgroundColor = NSColor.clear.cgColor

        video.contentsGravity = .resize
        layer?.addSublayer(video)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        video.frame = bounds
        CATransaction.commit()
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { handoff?() }
    override func rightMouseDown(with event: NSEvent) { handoff?() }
    override func scrollWheel(with event: NSEvent) { handoff?() }
}

final class Capture: NSObject, SCStreamOutput, SCStreamDelegate {
    var stream: SCStream?
    var frame: ((CapturedWindowFrame) -> Void)?
    let imageContext = CIContext(options: [.cacheIntermediates: false])
    var failed: ((String) -> Void)?
    var stopped = false
    private let deliveryLock = NSLock()
    private var pendingFrame: CapturedWindowFrame?
    private var deliveryScheduled = false
    var configuration: SCStreamConfiguration?
    var renderScale: CGFloat = 2
    var requestedSize = CGSize.zero
    var appliedSize = CGSize.zero
    var updating = false
    var geometryStabilizer = FrameGeometryStabilizer()
    var capturePadding: CGFloat {
        if #available(macOS 14, *) { return 128 }
        return 0
    }
    func resize(to size: CGSize) {
        requestedSize = CGSize(width: (size.width * renderScale).rounded() / renderScale,
                               height: (size.height * renderScale).rounded() / renderScale)
        guard !updating, size != appliedSize, let config = configuration, let stream = stream, !stopped else { return }
        updating = true
        Task { @MainActor in
            while !self.stopped && self.requestedSize != self.appliedSize {
                let next = self.requestedSize
                let scale = min(self.renderScale, 4096 / max(next.width + self.capturePadding, next.height + self.capturePadding))
                let width = max(2, Int(((next.width + self.capturePadding) * scale).rounded()))
                let height = max(2, Int(((next.height + self.capturePadding) * scale).rounded()))
                if width == config.width && height == config.height { self.appliedSize = next; continue }
                config.width = width; config.height = height
                do { try await stream.updateConfiguration(config); self.appliedSize = next }
                catch { self.failed?("调整画面尺寸失败：\(error.localizedDescription)"); break }
            }
            self.updating = false
        }
    }
    func makeConfiguration(size: CGSize, scale: CGFloat) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        renderScale = scale
        let limitedScale = min(scale, 4096 / max(size.width + capturePadding, size.height + capturePadding))
        config.width = max(2, Int(((size.width + capturePadding) * limitedScale).rounded()))
        config.height = max(2, Int(((size.height + capturePadding) * limitedScale).rounded()))
        requestedSize = size; appliedSize = size
        configuration = config
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 3
        config.showsCursor = false
        config.capturesAudio = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        // ScreenCaptureKit's documented default is transparent. Its backgroundColor
        // property is assign; do not pass a temporary AppKit CGColor into it.
        if #available(macOS 14, *) {
            config.shouldBeOpaque = false
            config.ignoreShadowsSingleWindow = false
        }
        return config
    }
    func start(window: SCWindow, scale: CGFloat) async throws {
        let config = makeConfiguration(size: window.frame.size, scale: scale)
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: config, delegate: self)
        self.stream = stream
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "windowpin.frames"))
        try await stream.startCapture()
        if stopped { try? await stream.stopCapture() }
    }
    func stop() {
        deliveryLock.lock(); stopped = true; pendingFrame = nil; deliveryLock.unlock()
        frame = nil; failed = nil
        if let stream = stream { Task { try? await stream.stopCapture() } }
        stream = nil
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, buffer.isValid, CMSampleBufferGetImageBuffer(buffer) != nil,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue else { return }
        guard let pixels = CMSampleBufferGetImageBuffer(buffer) else { return }
        let input = CIImage(cvPixelBuffer: pixels)
        guard let image = imageContext.createCGImage(input, from: input.extent) else { return }
        let metadata = attachments.first ?? [:]
        let native = completeWindowFrame(image: image, buffer: pixels, metadata: metadata)
        var sourceSize = native.windowRect.size
        if #available(macOS 13.1, *), let dictionary = metadata[.screenRect] as? [String: Any],
           let screen = CGRect(dictionaryRepresentation: dictionary as CFDictionary) { sourceSize = screen.size }
        let output = geometryStabilizer.accept(native, sourceSize: sourceSize)
        enqueueLatest(output)
    }
    private func enqueueLatest(_ output: CapturedWindowFrame) {
        deliveryLock.lock()
        guard !stopped else { deliveryLock.unlock(); return }
        pendingFrame = output
        guard !deliveryScheduled else { deliveryLock.unlock(); return }
        deliveryScheduled = true
        deliveryLock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.deliveryLock.lock()
            let newest = self.pendingFrame
            self.pendingFrame = nil; self.deliveryScheduled = false
            let stopped = self.stopped
            self.deliveryLock.unlock()
            if !stopped, let newest = newest { self.frame?(newest) }
        }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in if self?.stopped == false { self?.failed?(error.localizedDescription) } }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var status: NSStatusItem!
    var hotKey: EventHotKeyRef?
    var eventHandler: EventHandlerRef?
    var helpWindow: NSWindow!
    var permissionLabel: NSTextField!
    var stateLabel: NSTextField!
    var startButton: NSButton!
    var hoverButton: NSButton!
    var overlay: OverlayPair?
    var mirror: MirrorView?
    var interactionView: MirrorView?
    var capturedFrame: CapturedWindowFrame?
    var latestSourceFrame: CGRect?
    var activationObserver: NSObjectProtocol?
    var statusController: StatusButtonController?
    var statusMenu = NSMenu()
    var controlPermissionRow: NSStackView!
    var screenPermissionRow: NSStackView!
    var settingsStack: NSStackView!
    var permissionsStack: NSStackView!
    var permissionSeparator: NSBox!
    var hoverMonitor: HoverActivationMonitor?
    var capture: Capture?
    var target: AXUIElement?
    var targetPID: pid_t = 0
    var targetName = ""
    var targetID: CGWindowID = 0
    var hasFrame = false
    var starting = false
    var session = UUID()
    var lastState = "准备就绪：点击目标窗口，再按 Control + Option + T。"
    var timer: Timer?
    var errorReads = 0
    var shortcutOK = true
    var menuSignature = ""
    var displayedPinState: Bool?
    let handoffController = HandoffController()
    var lastExternalPID: pid_t = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--check-own-window") {
            validateOwnWindowCapture()
            return
        }
        NSApp.setActivationPolicy(.regular)
        UserDefaults.standard.register(defaults: ["hoverActivation": true])
        if !UserDefaults.standard.bool(forKey: "hoverDefaultV26") {
            UserDefaults.standard.set(true, forKey: "hoverActivation")
            UserDefaults.standard.set(true, forKey: "hoverDefaultV26")
        }
        let menu = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "设置", action: #selector(showHelp), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 StayPin", action: #selector(quit), keyEquivalent: "q").target = self
        let root = NSMenuItem(); root.submenu = appMenu; menu.addItem(root); NSApp.mainMenu = menu
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid() { lastExternalPID = front.processIdentifier }
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = status.button {
            statusController = StatusButtonController(button: button, click: { [weak self] in
                if CommandLine.arguments.contains("--trace-status") { print("STATUS_CLICK"); fflush(stdout) }
                self?.pinPrevious()
            }, menu: { [weak self] in
                if CommandLine.arguments.contains("--trace-status") { print("STATUS_MENU"); fflush(stdout) }
                return self?.statusMenu ?? NSMenu()
            })
        }
        if let icon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns").flatMap({ NSImage(contentsOf: $0) }) { NSApp.applicationIconImage = icon }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context = context else { return OSStatus(eventNotHandledErr) }
            Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue().toggle()
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        shortcutOK = RegisterEventHotKey(UInt32(kVK_ANSI_T), UInt32(controlKey | optionKey), EventHotKeyID(signature: 0x5750494E, id: 1), GetApplicationEventTarget(), 0, &hotKey) == noErr
        makeHelp()
        timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in self?.tick() }
        showHelp()
    }
    func validateOwnWindowCapture() {
        guard #available(macOS 14.4, *) else { print("SKIP: self-capture requires macOS 14.4"); exit(0) }
        NSApp.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 360, height: 240), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "窗口置顶 · 自有窗口捕获验证"
        window.backgroundColor = .systemBlue
        window.isReleasedWhenClosed = false
        helpWindow = window
        window.makeKeyAndOrderFront(nil)
        let capture = Capture(); self.capture = capture
        var frames = 0
        var transparent = false
        capture.frame = { frame in
            let image = frame.image
            frames += 1
            var rgba = [UInt8](repeating: 0, count: 4)
            rgba.withUnsafeMutableBytes { raw in
                if let context = CGContext(data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) {
                    context.setBlendMode(.copy)
                    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                }
            }
            transparent = transparent || rgba[3] < 64
            if frames == 1 {
                let rep = NSBitmapImageRep(cgImage: image)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: CommandLine.arguments.last!))
                }
            }
        }
        capture.failed = { message in print("FAIL: \(message)"); exit(1) }
        Task { @MainActor in
            do {
                let content = try await SCShareableContent.currentProcess
                guard let source = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { print("FAIL: own window missing"); exit(1) }
                try await capture.start(window: source, scale: 2)
                self.timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                    window.backgroundColor = frames % 2 == 0 ? .systemBlue : .systemGreen
                }
                try await Task.sleep(nanoseconds: 1_000_000_000)
                window.setContentSize(NSSize(width: 400, height: 260))
                capture.resize(to: CGSize(width: 400, height: 288))
                try await Task.sleep(nanoseconds: 3_000_000_000)
                self.timer?.invalidate(); capture.stop()
                guard frames >= 3, transparent else { print("FAIL: frames=\(frames), transparent=\(transparent)"); exit(1) }
                print("PASS: live own-window stream, \(frames) frames, transparent corner, resize, stop")
                exit(0)
            } catch { print("FAIL: \(error)"); exit(1) }
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showHelp(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func refresh() {
        let ax = AXIsProcessTrusted(), screen = CGPreflightScreenCaptureAccess()
        let pinned = target != nil
        let ordinary = ["准备就绪", "已取消置顶", "已固定", "正在操作原窗口", "请先完成下面两项权限", "正在切换到原窗口"].contains { lastState.hasPrefix($0) }
        stateLabel.stringValue = !shortcutOK ? "快捷键被占用，可使用菜单栏图钉。" : lastState
        stateLabel.isHidden = shortcutOK && (ordinary || !ax || !screen || starting)
        stateLabel.toolTip = lastState
        controlPermissionRow.isHidden = ax
        screenPermissionRow.isHidden = screen
        permissionsStack.isHidden = ax && screen
        permissionSeparator.isHidden = ax && screen
        let height = max(96, settingsStack.fittingSize.height + 40)
        if height.isFinite && abs(helpWindow.contentView!.bounds.height - height) > 1 {
            let top = helpWindow.frame.maxY
            helpWindow.setContentSize(NSSize(width: 300, height: height))
            helpWindow.setFrameOrigin(NSPoint(x: helpWindow.frame.minX, y: top - helpWindow.frame.height))
        }
        if displayedPinState != pinned {
            let icon = NSImage(systemSymbolName: pinned ? "pin.fill" : "pin", accessibilityDescription: pinned ? "已置顶" : "未置顶")
            icon?.isTemplate = true; status.button?.image = icon
            displayedPinState = pinned
        }
        status.button?.toolTip = pinned ? "已置顶：\(targetName) · 单击固定当前窗口，再点同一窗口取消 · 长按或右键打开菜单" : "单击置顶当前窗口 · 长按或右键打开菜单"
        if statusMenu.items.isEmpty {
            let options = NSMenu()
            options.addItem(withTitle: "设置", action: #selector(showHelp), keyEquivalent: "").target = self
            options.addItem(.separator())
            options.addItem(withTitle: "退出", action: #selector(quit), keyEquivalent: "").target = self
            options.delegate = self
            statusMenu = options
        }
        // Deliberately leave status.menu unset: a short click toggles pinning.
    }
    func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    func axRect(_ element: AXUIElement) -> CGRect? {
        guard let p = attribute(element, kAXPositionAttribute), let s = attribute(element, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size), size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: point, size: size)
    }
    @objc func pinPrevious() { toggle(usePrevious: true) }
    func toggle(usePrevious: Bool = false) {
        if starting { cancelPin(); return }
        guard AXIsProcessTrusted(), CGPreflightScreenCaptureAccess() else {
            lastState = "请先完成下面两项权限，再切回目标窗口按快捷键。"; showHelp(); return
        }
        let current = NSWorkspace.shared.frontmostApplication
        let candidate = usePrevious && current?.processIdentifier == getpid() ? NSRunningApplication(processIdentifier: lastExternalPID) : current
        guard let front = candidate, front.processIdentifier != getpid() else {
            lastState = "请点击要固定的其他应用窗口，再按快捷键。"; refresh(); return
        }
        let axApp = AXUIElementCreateApplication(front.processIdentifier)
        guard let value = attribute(axApp, kAXFocusedWindowAttribute), CFGetTypeID(value) == AXUIElementGetTypeID(),
              let rect = axRect(value as! AXUIElement) else {
            lastState = "无法读取此窗口，请改选普通应用窗口。"; showHelp(); return
        }
        let ax = value as! AXUIElement
        let pid = front.processIdentifier
        starting = true; session = UUID(); let token = session
        lastState = "正在获取目标窗口画面…"; refresh()
        Task { @MainActor [self] in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                guard self.session == token else { return }
                let candidates = content.windows.filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 }
                let match = candidates.min { self.distance($0.frame, rect) < self.distance($1.frame, rect) }
                guard let win = match, self.distance(win.frame, rect) < 30 else {
                    self.starting = false; self.lastState = "未找到与当前窗口匹配的可捕获画面。"; self.showHelp(); return
                }
                if self.target != nil && self.targetID == win.windowID && self.targetPID == pid {
                    self.cancelPin(); return
                }
                // Resolve the focused window before replacing the old pin.
                // Re-selecting the same window cancels; a different one switches.
                self.cancelPin()
                self.session = token; self.starting = true
                self.lastState = "正在获取目标窗口画面…"
                self.target = ax; self.targetPID = pid; self.targetID = win.windowID
                self.targetName = front.localizedName ?? "目标应用"; self.errorReads = 0
                self.refresh()
                self.latestSourceFrame = self.nsRect(rect)
                self.makeOverlay(frame: win.frame)
                let capture = Capture(); self.capture = capture
                capture.frame = { [weak self] frame in
                    guard let self = self, self.session == token else { return }
                    self.capturedFrame = frame
                    if let source = self.latestSourceFrame, let layer = self.mirror?.video {
                        self.overlay?.present(frame, source: source, layer: layer)
                        if let pair = self.overlay { self.hoverMonitor?.update(visible: pair.isVisible, rectangle: pair.input.frame) }
                    }
                    if !self.hasFrame { self.hasFrame = true; self.starting = false; self.lastState = "已固定：\(self.targetName) · 再按 ⌃⌥T 取消"; self.refresh(); self.tick() }
                }
                capture.failed = { [weak self] message in self?.fail("画面捕获已停止：\(message)") }
                try await capture.start(window: win, scale: NSScreen.main?.backingScaleFactor ?? 2)
                guard self.session == token else { capture.stop(); return }
                // A successful stream start is not proof that frames are arriving.
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                    guard let self = self, self.session == token, !self.hasFrame else { return }
                    self.fail("未收到窗口画面。请检查录屏权限，必要时退出并重开应用。")
                }
            } catch {
                guard self.session == token else { return }
                self.fail("无法捕获窗口：\(error.localizedDescription)")
            }
        }
    }
    func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.minX-b.minX) + abs(a.minY-b.minY) + abs(a.width-b.width) + abs(a.height-b.height)
    }
    func nsRect(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: (NSScreen.screens.first?.frame.maxY ?? 0) - rect.maxY, width: rect.width, height: rect.height)
    }
    func makeOverlay(frame: CGRect) {
        let source = nsRect(frame)
        let visualView = MirrorView(frame: CGRect(origin: .zero, size: source.size))
        let inputView = MirrorView(frame: CGRect(origin: .zero, size: source.size))
        // A near-transparent hit plane has no border and no shadow. Its bounds
        // are the original window only, excluding all captured shadow margins.
        inputView.layer?.backgroundColor = NSColor(white: 1, alpha: 0.001).cgColor
        inputView.handoff = { [weak self] in self?.handoff() }
        let pair = OverlayPair(sourceFrame: source, visualView: visualView, inputView: inputView)
        pair.visual.setAccessibilityLabel("\(targetName)的置顶实时画面")
        pair.input.setAccessibilityLabel("\(targetName)的置顶窗口操作区域，点击返回原窗口")
        overlay = pair; mirror = visualView; interactionView = inputView
        hoverMonitor = HoverActivationMonitor(enabled: hoverButton.state == .on, canActivate: { [weak self] in
            guard let pair = self?.overlay, let top = topVisibleWindow(at: NSEvent.mouseLocation) else { return false }
            return top == CGWindowID(pair.input.windowNumber) || top == CGWindowID(pair.visual.windowNumber)
        }) { [weak self] in self?.handoff(fromHover: true) }
    }
    func tick() {
        // Permission checks do not show prompts or open settings.
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if let pid = frontPID, pid != getpid() { lastExternalPID = pid }
        if target == nil { refresh(); return }
        if helpWindow.isVisible && frontPID == getpid() && !handoffController.isPending {
            overlay?.orderOut(nil)
            if let pair = overlay { hoverMonitor?.update(visible: false, rectangle: pair.input.frame) }
            return
        }
        guard AXIsProcessTrusted(), CGPreflightScreenCaptureAccess() else { fail("权限已撤销，已取消置顶。请重新开启权限。"); return }
        guard let target = target, let app = NSRunningApplication(processIdentifier: targetPID), !app.isTerminated else { cancelPin(); return }
        guard let rect = axRect(target) else {
            errorReads += 1
            if errorReads > 12 { fail("原窗口已关闭或无法访问，已取消置顶。") }
            return
        }
        errorReads = 0
        let hidden = app.isHidden || (attribute(target, kAXMinimizedAttribute) as? Bool == true)
        // Hide only after the real source is confirmed in front. Another
        // window belonging to the same app is not sufficient.
        let originalActive = frontPID == targetPID && frontNormalWindowID() == targetID
        // Native menus and child panels can momentarily lead WindowServer's
        // ordering while the original remains the source app's main window.
        let stillEditingOriginal = overlay?.isVisible == false && frontPID == targetPID &&
            (attribute(target, kAXMainAttribute) as? Bool == true)
        if handoffController.isPending {
            switch handoffController.poll(frontPID: frontPID, originalIsReady: originalActive) {
            case .ready:
                lastState = "正在操作原窗口 · 切换应用后自动恢复置顶画面"; refresh()
            case .failed(let reason):
                // An activation failure must never destroy a valid pin.
                lastState = reason; refresh()
            case .pending:
                if originalActive { DispatchQueue.main.async { [weak self] in self?.tick() } }
            case .idle: break
            }
        }
        if hidden || ((originalActive || stillEditingOriginal) && !handoffController.isPending) || !hasFrame {
            if overlay?.isVisible == true { overlay?.orderOut(nil) }
            if let pair = overlay { hoverMonitor?.update(visible: false, rectangle: pair.input.frame) }
            return
        }
        capture?.resize(to: rect.size)
        let source = nsRect(rect)
        latestSourceFrame = source
        let presentation = capturedFrame?.presentationFrame(for: source) ?? source
        overlay?.setFrames(source: source, presentation: presentation)
        if overlay?.isVisible == false {
            overlay?.show()
        }
        if let pair = overlay { hoverMonitor?.update(visible: pair.isVisible, rectangle: pair.input.frame) }
    }
    func handoff(fromHover: Bool = false) {
        guard let target = target, let app = NSRunningApplication(processIdentifier: targetPID), !handoffController.isPending else { return }
        // Keep the mirror in place throughout activation. Hide the guide so it
        // does not cover the source when our app briefly receives activation.
        helpWindow?.orderOut(nil)
        handoffController.begin(application: app, preferWorkspace: fromHover) {
            AXUIElementPerformAction(target, kAXRaiseAction as CFString) == .success
        }
        lastState = "正在切换到原窗口…（置顶保留）"; refresh()
    }
    @objc func cancelPin() {
        session = UUID(); starting = false; hasFrame = false; handoffController.cancel()
        hoverMonitor?.stop(); hoverMonitor = nil
        capture?.stop(); capture = nil
        overlay?.orderOut(nil); overlay?.close(); overlay = nil; mirror = nil; interactionView = nil; capturedFrame = nil; latestSourceFrame = nil
        target = nil; targetPID = 0; targetID = 0; targetName = ""
        lastState = "已取消置顶。点击目标窗口，按 ⌃⌥T 重新固定。"; refresh()
    }
    func fail(_ message: String) { cancelPin(); lastState = message; showHelp() }
    @objc func requestAX() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc func requestScreen() {
        _ = CGRequestScreenCaptureAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
    @objc func checkPermissions() { refresh() }
    func menuWillOpen(_ menu: NSMenu) { hoverMonitor?.enabled = false }
    func menuDidClose(_ menu: NSMenu) { hoverMonitor?.enabled = hoverButton.state == .on }
    @objc func toggleHover() {
        let enabled = hoverButton.state == .on
        UserDefaults.standard.set(enabled, forKey: "hoverActivation")
        hoverMonitor?.enabled = enabled
    }
    @objc func ready() { helpWindow.close() }
    @objc func quit() { cancelPin(); NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) {
        hoverMonitor?.stop(); capture?.stop(); timer?.invalidate()
        if let observer = activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        if let hotKey = hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler = eventHandler { RemoveEventHandler(eventHandler) }
    }
    @objc func showHelp() { refresh(); helpWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    func makeHelp() {
        helpWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 210), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        helpWindow.title = "设置"
        helpWindow.isReleasedWhenClosed = false; helpWindow.animationBehavior = .none
        let root = helpWindow.contentView!
        func label(_ text: String) -> NSTextField {
            let field = NSTextField(wrappingLabelWithString: text)
            field.font = .systemFont(ofSize: 13)
            return field
        }
        func row(_ views: [NSView]) -> NSStackView {
            let stack = NSStackView(views: views); stack.orientation = .horizontal
            stack.alignment = .centerY; stack.spacing = 8; return stack
        }
        func spacer() -> NSView {
            let view = NSView(); view.setContentHuggingPriority(.defaultLow, for: .horizontal); return view
        }
        hoverButton = NSButton(checkboxWithTitle: "移入即可操作", target: self, action: #selector(toggleHover))
        hoverButton.state = UserDefaults.standard.bool(forKey: "hoverActivation") ? .on : .off
        hoverButton.toolTip = "移入置顶画面时返回原窗口；画面出现在鼠标下方时，移出后再移入。"
        let shortcutTitle = label("快捷键"); shortcutTitle.textColor = .secondaryLabelColor
        let shortcut = label("⌃ ⌥ T"); shortcut.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        let shortcutRow = row([shortcutTitle, spacer(), shortcut])
        permissionSeparator = NSBox(); permissionSeparator.boxType = .separator
        func permissionRow(_ title: String, _ action: Selector) -> NSStackView {
            let button = NSButton(title: "开启", target: self, action: action); button.bezelStyle = .rounded
            button.widthAnchor.constraint(equalToConstant: 62).isActive = true
            let stack = row([label(title), spacer(), button])
            stack.heightAnchor.constraint(equalToConstant: 28).isActive = true
            return stack
        }
        controlPermissionRow = permissionRow("设备控制", #selector(requestAX))
        screenPermissionRow = permissionRow("屏幕录制", #selector(requestScreen))
        permissionsStack = NSStackView(views: [controlPermissionRow, screenPermissionRow])
        permissionsStack.orientation = .vertical; permissionsStack.alignment = .leading
        permissionsStack.spacing = 8; permissionsStack.detachesHiddenViews = true
        for child in [controlPermissionRow!, screenPermissionRow!] { child.widthAnchor.constraint(equalTo: permissionsStack.widthAnchor).isActive = true }
        stateLabel = label(""); stateLabel.textColor = .secondaryLabelColor
        stateLabel.maximumNumberOfLines = 2
        settingsStack = NSStackView(views: [hoverButton, shortcutRow, permissionSeparator, permissionsStack, stateLabel])
        settingsStack.orientation = .vertical; settingsStack.alignment = .leading
        settingsStack.spacing = 14; settingsStack.detachesHiddenViews = true
        settingsStack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(settingsStack)
        NSLayoutConstraint.activate([
            settingsStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            settingsStack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            settingsStack.widthAnchor.constraint(equalToConstant: 260)
        ])
        for child in [shortcutRow, permissionSeparator!, permissionsStack!, stateLabel!] as [NSView] { child.widthAnchor.constraint(equalTo: settingsStack.widthAnchor).isActive = true }
        helpWindow.center()
    }

}
if CommandLine.arguments.contains("--check-capture-config") {
    // Exercise the production configuration on the same background executor class
    // as SCStream initialization, including copies after draining autorelease pools.
    let completed = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
        let capture = Capture()
        for i in 0..<2000 {
            let size = CGSize(width: 640 + i % 20, height: 480)
            let config = autoreleasepool { capture.makeConfiguration(size: size, scale: 2) }
            for _ in 0..<5 {
                autoreleasepool {
                    let copy = config.copy() as! SCStreamConfiguration
                    precondition(copy.width == Int((size.width + capture.capturePadding) * 2))
                    precondition(copy.height == Int((480 + capture.capturePadding) * 2))
                    precondition(copy.backgroundColor.alpha == 0)
                    precondition(copy.pixelFormat == kCVPixelFormatType_32BGRA)
                    if #available(macOS 14, *) { precondition(!copy.shouldBeOpaque) }
                }
            }
        }
        print("PASS: 2000 production configurations, 10000 background copies, transparent alpha")
        completed.signal()
    }
    precondition(completed.wait(timeout: .now() + 60) == .success)
    exit(0)
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
