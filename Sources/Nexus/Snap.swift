import AppKit
import ApplicationServices
import QuartzCore

// MARK: - Targets

struct SnapTarget {
    let rect: CGRect // overlay coords (AppKit, origin bottom-left of our screen)
    let role: String

    /// Small targets (buttons, icons) snap to their center. Big ones (text fields, rows,
    /// title bars) just pull the pointer inside, so you can still point anywhere within them.
    var isSmall: Bool { rect.width <= Snapper.smallMaxPx && rect.height <= Snapper.smallMaxPx }
}

// MARK: - Scanner

/// Reads clickable UI elements from the macOS Accessibility tree. Runs on its own queue:
/// every AX read is an IPC call into the other app, and big apps can take tens of ms.
/// Only the part of the window near the pointer is walked, so it stays fast.
final class UIScanner {
    var onTargets: (([SnapTarget]) -> Void)? // delivered on main

    static let interval = 0.3       // s between scans
    static let searchRadius = 380.0 // px around the pointer; subtrees outside this are skipped
    static let maxVisited = 900
    static let maxTargets = 400
    static let maxDepth = 40
    static let titleBarHeight: CGFloat = 28

    static let clickableRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton",
        "AXLink", "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField",
        "AXMenuBarItem", "AXMenuItem", "AXDockItem", "AXSlider", "AXDisclosureTriangle",
        "AXIncrementor", "AXColorWell", "AXRow", "AXCell",
    ]

    private let queue = DispatchQueue(label: "nexus.ax", qos: .utility) // below hand tracking
    private var lastScanPoint: CGPoint?
    private let screenFrame: CGRect
    private let primaryHeight: CGFloat
    private let ownPid = ProcessInfo.processInfo.processIdentifier
    private var busy = false
    private var lastScan = 0.0
    private var slowScans = 0
    private var webEnabled: Set<pid_t> = []

    init(screen: NSScreen) {
        screenFrame = screen.frame
        primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
    }

    /// Main thread. `p` is the pointer in overlay coords. Rate limited, and skipped entirely
    /// while the pointer sits still (log 20260924-004426: 483 scans in 3 minutes).
    func requestScan(near p: CGPoint) {
        let now = CACurrentMediaTime()
        guard !busy, now - lastScan >= Self.interval else { return }
        if let last = lastScanPoint, distance(last, p) < 60, now - lastScan < 1.5 { return }
        lastScanPoint = p
        busy = true
        lastScan = now
        let g = global(p)
        let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let dockPid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier

        queue.async { [self] in
            let start = CACurrentMediaTime()
            var out: [SnapTarget] = []
            var visited = 0
            let windows = onScreenWindows()

            // 1. Title bars of visible windows, unless another window covers them
            for (i, w) in windows.enumerated() {
                let bar = CGRect(x: w.bounds.minX, y: w.bounds.minY, width: w.bounds.width, height: Self.titleBarHeight)
                let mid = CGPoint(x: bar.midX, y: bar.midY)
                if !windows[..<i].contains(where: { $0.bounds.contains(mid) }) {
                    out.append(SnapTarget(rect: toOverlay(bar), role: "titlebar"))
                }
            }

            // 2. Buttons, links, fields... in the window under the pointer
            let area = CGRect(x: g.x - Self.searchRadius, y: g.y - Self.searchRadius,
                              width: Self.searchRadius * 2, height: Self.searchRadius * 2)
            if let w = windows.first(where: { $0.bounds.contains(g) }), let axWin = axWindow(pid: w.pid, bounds: w.bounds) {
                collect(axWin, depth: 0, area: area, visited: &visited, into: &out)
            }

            // 3. Menu bar of the frontmost app, 4. Dock icons
            if let pid = frontPid, pid != ownPid {
                let app = appElement(pid)
                if let bar = element(app, kAXMenuBarAttribute) {
                    collect(bar, depth: 0, area: nil, visited: &visited, into: &out)
                }
            }
            if let pid = dockPid {
                collect(appElement(pid), depth: 0, area: nil, visited: &visited, into: &out)
            }

            let ms = (CACurrentMediaTime() - start) * 1000
            if ms > 150 {
                slowScans += 1
                if slowScans <= 5 || slowScans % 20 == 0 {
                    logWarn("snap", "scan_slow", ["ms": ms, "visited": visited, "count": slowScans])
                }
            }
            logDebug("snap", "scan", ["targets": out.count, "visited": visited, "ms": ms])
            DispatchQueue.main.async {
                self.busy = false
                self.onTargets?(out)
            }
        }
    }

    // MARK: AX helpers (scanner queue only)

    private func appElement(_ pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.05) // a hung app must never stall us
        if !webEnabled.contains(pid) {
            // Chrome/Electron only expose their page elements once asked to
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            webEnabled.insert(pid)
        }
        return app
    }

    private func element(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success, let v,
              CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    private func axWindow(pid: pid_t, bounds: CGRect) -> AXUIElement? {
        let app = appElement(pid)
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &v) == .success,
              let wins = v as? [AXUIElement] else { return nil }
        // Match the AX window to the on-screen window by frame
        var best: (AXUIElement, CGFloat)?
        for w in wins {
            guard let f = frame(w) else { continue }
            let err = abs(f.minX - bounds.minX) + abs(f.minY - bounds.minY) + abs(f.width - bounds.width) + abs(f.height - bounds.height)
            if best == nil || err < best!.1 { best = (w, err) }
        }
        return best.flatMap { $0.1 < 40 ? $0.0 : nil } ?? wins.first
    }

    private func frame(_ el: AXUIElement) -> CGRect? {
        var p: CFTypeRef?, s: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &p) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &s) == .success
        else { return nil }
        return rect(p, s)
    }

    private func rect(_ p: CFTypeRef?, _ s: CFTypeRef?) -> CGRect? {
        guard let p, let s, CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &origin),
              AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// Depth-first walk. One batched IPC call per element (role, position, size, children).
    private func collect(_ el: AXUIElement, depth: Int, area: CGRect?, visited: inout Int, into out: inout [SnapTarget]) {
        guard depth <= Self.maxDepth, visited < Self.maxVisited, out.count < Self.maxTargets else { return }
        visited += 1

        let names = [kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXChildrenAttribute] as CFArray
        var raw: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(el, names, AXCopyMultipleAttributeOptions(rawValue: 0), &raw) == .success,
              let vals = raw as? [AnyObject], vals.count == 4 else { return }

        let role = vals[0] as? String ?? ""
        let r = rect(vals[1], vals[2])

        // Skip whole subtrees that are nowhere near the pointer
        if let area, let r, r.width > 0, r.height > 0, !r.intersects(area) { return }

        if Self.clickableRoles.contains(role), let r, r.width >= 6, r.height >= 6 {
            let rowish = role == "AXRow" || role == "AXCell"
            if !rowish || r.height <= 60 {
                out.append(SnapTarget(rect: toOverlay(r), role: role))
            }
            if !rowish { return } // don't descend into buttons; rows/cells may hold buttons
        }

        guard let kids = vals[3] as? [AXUIElement] else { return }
        for k in kids {
            collect(k, depth: depth + 1, area: area, visited: &visited, into: &out)
        }
    }

    private struct Win { let pid: pid_t; let bounds: CGRect }

    /// Normal app windows, front to back, in global coords (origin top-left of primary display).
    private func onScreenWindows() -> [Win] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != ownPid,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: dict),
                  b.width > 60, b.height > 40
            else { return nil }
            return Win(pid: pid, bounds: b)
        }
    }

    // MARK: Coordinates

    private func global(_ p: CGPoint) -> CGPoint {
        CGPoint(x: screenFrame.minX + p.x, y: primaryHeight - (screenFrame.minY + p.y))
    }

    private func toOverlay(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX - screenFrame.minX, y: primaryHeight - r.maxY - screenFrame.minY,
               width: r.width, height: r.height)
    }
}

// MARK: - Snapper

/// Magnetic targets: when the pointer comes near a button it jumps onto it and stays there
/// until you clearly move away. Makes small targets easy to hit and hides hand tremor.
final class Snapper {
    var enabled = true
    var targets: [SnapTarget] = []
    private(set) var current: SnapTarget?

    static let capturePx = 22.0 // how close you need to get to grab a target
    static let releasePx = 34.0 // how far past its edge you need to go to let go (hysteresis)
    static let smallMaxPx: CGFloat = 90

    func apply(_ p: CGPoint) -> CGPoint {
        guard enabled, !targets.isEmpty else {
            current = nil
            return p
        }

        if let c = current {
            let keep = c.rect.insetBy(dx: -Self.releasePx, dy: -Self.releasePx).contains(p)
            // Pointer is outside the current target and right on top of another one: switch now.
            // Without this, neighbors (Dock icons, toolbar buttons) were sticky, because the
            // release margin of one overlapped the next.
            if keep, !c.rect.contains(p), let other = directlyOver(p), other.rect != c.rect {
                switchTo(other)
                return anchor(other, p)
            }
            // A big target (title bar, row) gives way to a small one inside it
            if keep, !c.isSmall, let small = best(near: p, smallOnly: true) {
                switchTo(small)
                return anchor(small, p)
            }
            if keep { return anchor(c, p) }
            logDebug("snap", "release", ["role": c.role])
            current = nil
        }

        if let t = best(near: p, smallOnly: false) {
            switchTo(t)
            return anchor(t, p)
        }
        return p
    }

    func reset() { current = nil }

    private func switchTo(_ t: SnapTarget) {
        if current?.rect != t.rect { logDebug("snap", "capture", ["role": t.role, "w": Double(t.rect.width), "h": Double(t.rect.height)]) }
        current = t
    }

    /// The smallest target the pointer is actually inside, if any.
    private func directlyOver(_ p: CGPoint) -> SnapTarget? {
        targets.filter { $0.rect.contains(p) }.min { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }
    }

    /// Nearest target within capture range. Small targets win over big ones that contain them.
    private func best(near p: CGPoint, smallOnly: Bool) -> SnapTarget? {
        var winner: (SnapTarget, Double)?
        for t in targets where !smallOnly || t.isSmall {
            let d = Self.distance(p, t.rect)
            guard d <= Self.capturePx else { continue }
            let score = d + (t.isSmall ? 0 : Self.capturePx) + Double(t.rect.width * t.rect.height) * 1e-6
            if winner == nil || score < winner!.1 { winner = (t, score) }
        }
        return winner?.0
    }

    private func anchor(_ t: SnapTarget, _ p: CGPoint) -> CGPoint {
        if t.isSmall { return CGPoint(x: t.rect.midX, y: t.rect.midY) }
        let inner = t.rect.insetBy(dx: min(8, t.rect.width / 2), dy: min(6, t.rect.height / 2))
        return CGPoint(x: min(max(p.x, inner.minX), inner.maxX), y: min(max(p.y, inner.minY), inner.maxY))
    }

    private static func distance(_ p: CGPoint, _ r: CGRect) -> Double {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return Double(hypot(dx, dy))
    }
}
