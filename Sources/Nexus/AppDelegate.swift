import AppKit
import AVFoundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let camera = CameraCapture()
    private var engine: TrackingEngine!
    private var overlay: OverlayController!
    private var mouse: MouseController!
    private let snapper = Snapper()
    private var scanner: UIScanner!
    private var lastPinch: PinchState = .open
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.main else {
            logError("app", "no_screen")
            NSApp.terminate(nil)
            return
        }
        var info = systemInfo()
        info["screen"] = "\(Int(screen.frame.width))x\(Int(screen.frame.height))"
        info["scale"] = Double(screen.backingScaleFactor)
        info["screens"] = NSScreen.screens.count
        logInfo("app", "start", info)

        overlay = OverlayController(screen: screen)
        mouse = MouseController(screen: screen)
        mouse.requestAccess()
        engine = TrackingEngine(screenSize: screen.frame.size, queue: camera.queue)
        engine.onUpdate = { [weak self] state in
            DispatchQueue.main.async { self?.handle(state) }
        }
        overlay.onFrame = { [weak self] p, _ in
            self?.mouse.move(to: p)
            self?.scanner.requestScan(near: p)
        }
        scanner = UIScanner(screen: screen)
        scanner.onTargets = { [weak self] targets in self?.snapper.targets = targets }
        overlay.snapper = snapper
        camera.onFrame = { [weak self] buffer in self?.engine.process(buffer) }
        camera.onDrop = { [weak self] in self?.engine.noteDroppedFrame() }
        buildMenu()
        startCamera()
    }

    /// Main thread, once per camera frame.
    private func handle(_ state: PointerState) {
        overlay.render(state)
        if state.pinch != lastPinch {
            // Click where the pointer is DRAWN (smoothed + snapped), not the raw hand position
            let at = overlay.output ?? state.position
            if state.pinch == .pinched {
                mouse.press(at: at)
            } else {
                mouse.release(at: at)
            }
            lastPinch = state.pinch
        }
        if !state.handVisible && state.visibility <= 0 { mouse.releaseIfDown() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        mouse?.releaseIfDown()
        logInfo("app", "quit")
        Log.shared.flush()
    }

    // MARK: - Camera

    private func startCamera() {
        logInfo("camera", "permission_status", ["status": AVCaptureDevice.authorizationStatus(for: .video).rawValue])
        AVCaptureDevice.requestAccess(for: .video) { granted in
            logInfo("camera", "permission_result", ["granted": granted])
            guard granted else {
                self.fail("Camera access denied. Turn it on in System Settings → Privacy & Security → Camera.")
                return
            }
            self.camera.queue.async {
                do { try self.camera.start() } catch { self.fail("\(error)") }
            }
        }
    }

    private func fail(_ message: String) {
        logError("app", "fatal", ["message": message])
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Nexus"
            alert.informativeText = message
            alert.runModal()
        }
    }

    // MARK: - Menu bar

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "hand.point.up.left", accessibilityDescription: "Nexus")

        let menu = NSMenu()

        let sensMenu = NSMenu()
        for s in Sensitivity.allCases {
            let i = item(s.rawValue.capitalized, #selector(pickSensitivity(_:)), on: s == .high)
            i.representedObject = s.rawValue
            sensMenu.addItem(i)
        }
        let sensItem = NSMenuItem(title: "Sensitivity (higher = less hand movement)", action: nil, keyEquivalent: "")
        sensItem.submenu = sensMenu
        menu.addItem(sensItem)
        menu.addItem(item("Control real mouse (pinch = click)", #selector(toggleMouse(_:)), on: true))
        menu.addItem(item("Snap to buttons & windows", #selector(toggleSnap(_:)), on: true))
        menu.addItem(.separator())
        menu.addItem(item("Trackpad mode (off = direct pointing)", #selector(toggleMode(_:)), on: false))
        menu.addItem(item("Smoothing filter", #selector(toggleFilter(_:)), on: true))

        let anchorMenu = NSMenu()
        for a in PointerAnchor.allCases {
            let i = item(a.rawValue.capitalized, #selector(pickAnchor(_:)), on: a == .palm)
            i.representedObject = a.rawValue
            anchorMenu.addItem(i)
        }
        let anchorItem = NSMenuItem(title: "Point with", action: nil, keyEquivalent: "")
        anchorItem.submenu = anchorMenu
        menu.addItem(anchorItem)
        menu.addItem(item("Show metrics", #selector(toggleMetrics(_:)), on: true))
        menu.addItem(item("Record run to CSV", #selector(toggleRecording(_:)), on: false))
        menu.addItem(item("Show log file in Finder", #selector(revealLog)))
        menu.addItem(.separator())
        menu.addItem(item("Quit Nexus", #selector(quit), key: "q"))
        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector, on: Bool? = nil, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        if let on { i.state = on ? .on : .off }
        return i
    }

    private func flip(_ item: NSMenuItem) -> Bool {
        item.state = item.state == .on ? .off : .on
        return item.state == .on
    }

    private func setting(_ name: String, _ value: Any) {
        logInfo("settings", "changed", ["setting": name, "value": value])
    }

    @objc private func pickSensitivity(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let s = Sensitivity(rawValue: raw) else { return }
        sender.menu?.items.forEach { $0.state = $0 === sender ? .on : .off }
        setting("sensitivity", s.rawValue)
        engine.update { $0.sensitivity = s }
    }

    @objc private func toggleMouse(_ sender: NSMenuItem) {
        let on = flip(sender)
        if !on { mouse.releaseIfDown() }
        mouse.enabled = on
        if on && !mouse.trusted { mouse.requestAccess() }
        setting("real_mouse", on)
    }

    @objc private func toggleSnap(_ sender: NSMenuItem) {
        snapper.enabled = flip(sender)
        snapper.reset()
        setting("snap", snapper.enabled)
    }

    @objc private func toggleFilter(_ sender: NSMenuItem) {
        let on = flip(sender)
        setting("filter", on)
        engine.update {
            $0.filterEnabled = on
            $0.resetFilters()
        }
    }

    @objc private func toggleMode(_ sender: NSMenuItem) {
        let trackpad = flip(sender)
        setting("mode", trackpad ? "trackpad" : "direct")
        engine.update {
            $0.mode = trackpad ? .trackpad : .direct
            $0.resetFilters()
        }
    }

    @objc private func pickAnchor(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let anchor = PointerAnchor(rawValue: raw) else { return }
        sender.menu?.items.forEach { $0.state = $0 === sender ? .on : .off }
        setting("anchor", anchor.rawValue)
        engine.update {
            $0.anchor = anchor
            $0.resetFilters()
        }
    }

    @objc private func toggleMetrics(_ sender: NSMenuItem) {
        overlay.showMetrics = flip(sender)
        setting("show_metrics", overlay.showMetrics)
    }

    @objc private func toggleRecording(_ sender: NSMenuItem) {
        _ = flip(sender)
        engine.update { _ = $0.toggleRecording() }
    }

    @objc private func revealLog() {
        guard let url = Log.shared.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
