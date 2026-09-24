import AppKit
import ApplicationServices
import QuartzCore

/// Drives the real macOS cursor: move, click, double-click, drag.
/// Clicks need Accessibility permission (System Settings -> Privacy & Security ->
/// Accessibility -> enable Terminal, or whatever app launched Nexus). Without it the
/// cursor still moves, it just can't click.
final class MouseController {
    var enabled = true

    private(set) var trusted = AXIsProcessTrusted()
    private let source = CGEventSource(stateID: .hidSystemState)
    private let screenFrame: CGRect
    private let primaryHeight: CGFloat
    private var isDown = false
    private var lastPosted: CGPoint?
    private var lastUp: (t: Double, pos: CGPoint)?
    private var clickCount = 1

    static let doubleClickTime = 0.4 // s
    static let doubleClickPx = 12.0

    init(screen: NSScreen) {
        screenFrame = screen.frame
        primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        // Posted events otherwise make macOS ignore real mouse input for 250ms
        source?.localEventsSuppressionInterval = 0
    }

    func requestAccess() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        trusted = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        logInfo("mouse", "accessibility", ["trusted": trusted])
    }

    /// `p` is in overlay coords (AppKit, origin bottom-left of our screen).
    func move(to p: CGPoint) {
        guard enabled else { return }
        let g = global(p)
        if let last = lastPosted, distance(last, g) < 0.5 { return }
        lastPosted = g
        if trusted {
            // Real move events, so hover effects and tooltips work
            CGEvent(mouseEventSource: source, mouseType: isDown ? .leftMouseDragged : .mouseMoved,
                    mouseCursorPosition: g, mouseButton: .left)?.post(tap: .cghidEventTap)
        } else {
            CGWarpMouseCursorPosition(g)
        }
    }

    func press(at p: CGPoint) {
        guard enabled else { return }
        guard trusted else {
            logWarn("mouse", "click_blocked", ["reason": "no accessibility permission"])
            return
        }
        let g = global(p)
        let now = CACurrentMediaTime()
        if let up = lastUp, now - up.t < Self.doubleClickTime, distance(up.pos, g) < Self.doubleClickPx {
            clickCount += 1
        } else {
            clickCount = 1
        }
        post(.leftMouseDown, at: g)
        isDown = true
        lastPosted = g
        logInfo("mouse", "down", ["pos": g, "click_count": clickCount])
    }

    func release(at p: CGPoint) {
        guard isDown else { return }
        let g = global(p)
        post(.leftMouseUp, at: g)
        isDown = false
        lastUp = (CACurrentMediaTime(), g)
        logInfo("mouse", "up", ["pos": g, "click_count": clickCount])
    }

    /// Always call when disabling or losing the hand, so a button is never left held down.
    func releaseIfDown() {
        if isDown, let p = lastPosted {
            post(.leftMouseUp, at: p)
            isDown = false
            logInfo("mouse", "up", ["pos": p, "reason": "forced"])
        }
    }

    private func post(_ type: CGEventType, at g: CGPoint) {
        let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: g, mouseButton: .left)
        e?.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        e?.post(tap: .cghidEventTap)
    }

    /// AppKit (bottom-left origin, per screen) -> CoreGraphics global (top-left of primary display).
    private func global(_ p: CGPoint) -> CGPoint {
        CGPoint(x: screenFrame.minX + p.x, y: primaryHeight - (screenFrame.minY + p.y))
    }
}
