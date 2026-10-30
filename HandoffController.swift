import Cocoa

// Used by the app and the independent UI activation probe. All methods run on
// the main thread. The floating image stays visible until .ready is returned.
final class HandoffController {
    enum Outcome { case idle, pending, ready, failed(String) }
    private enum Phase { case idle, helper, target }
    private var phase = Phase.idle
    private var application: NSRunningApplication?
    private var prepareOriginal: (() -> Bool)?
    private var raised = false
    private var deadline: TimeInterval = 0
    private var fallbackAt: TimeInterval = 0
    private var fallbackRequested = false
    var diagnostic: ((String) -> Void)?
    var isPending: Bool { phase != .idle }

    func begin(application: NSRunningApplication, preferWorkspace: Bool = false, prepareOriginal: @escaping () -> Bool) {
        precondition(Thread.isMainThread)
        guard !isPending else { return }
        self.application = application
        self.prepareOriginal = prepareOriginal
        raised = false
        phase = .helper
        deadline = ProcessInfo.processInfo.systemUptime + 6
        fallbackAt = ProcessInfo.processInfo.systemUptime + 0.8
        fallbackRequested = false
        diagnostic?("begin target=\(application.processIdentifier), front=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)")
        if preferWorkspace {
            // Hover has no click activation token. Launch Services can activate
            // the existing source directly, without an intermediate app switch.
            phase = .target
            requestWorkspaceActivation(application)
            return
        }
        // A nonactivating panel does not own activation. Take activation only
        // in response to the user's click, then explicitly yield it to the app.
        if #available(macOS 14, *) { NSApp.activate() }
        else { NSApp.activate(ignoringOtherApps: true) }
    }
    func poll(frontPID: pid_t?, originalIsReady: Bool) -> Outcome {
        precondition(Thread.isMainThread)
        guard isPending, let application = application else { return .idle }
        if application.isTerminated { return failure("目标应用已退出。") }
        if frontPID == application.processIdentifier {
            if !raised {
                raised = true
                guard prepareOriginal?() == true else { return failure("原窗口暂时无法抬到前面。置顶已保留。") }
                diagnostic?("target active; prepare window")
                // WindowServer ordering is asynchronous; confirm it next turn.
                return .pending
            }
            if originalIsReady { cancel(); return .ready }
        } else if phase == .helper && frontPID == getpid() {
            phase = .target
            if #available(macOS 14, *) {
                NSApp.yieldActivation(to: application)
                let accepted = application.activate(from: .current, options: [])
                diagnostic?("yield accepted=\(accepted)")
            } else { _ = application.activate(options: [.activateIgnoringOtherApps]) }
        }
        if !fallbackRequested && ProcessInfo.processInfo.systemUptime > fallbackAt {
            diagnostic?("workspace fallback; front=\(frontPID ?? 0)")
            requestWorkspaceActivation(application)
        }
        if ProcessInfo.processInfo.systemUptime > deadline {
            return failure("原窗口未能切到前台。置顶已保留，可手动切回或再次点击。")
        }
        return .pending
    }
    private func requestWorkspaceActivation(_ application: NSRunningApplication) {
        guard let url = application.bundleURL else { return }
        fallbackRequested = true
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        configuration.promptsUserIfNeeded = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
    }
    private func failure(_ message: String) -> Outcome { diagnostic?("failure front=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)"); cancel(); return .failed(message) }
    func cancel() {
        phase = .idle; application = nil; prepareOriginal = nil; raised = false
    }
}

// Ignore tiny AppKit helper windows and floating panels. Actual source-window
// order, rather than AX wrapper equality, decides whether the overlay can hide.
func frontNormalWindowID() -> CGWindowID? {
    guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
    return windows.first { row in
        guard row[kCGWindowLayer as String] as? Int == 0,
              let bounds = row[kCGWindowBounds as String] as? [String: CGFloat] else { return false }
        return (bounds["Width"] ?? 0) > 60 && (bounds["Height"] ?? 0) > 60
    }.flatMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
}
