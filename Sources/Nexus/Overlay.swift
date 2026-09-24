import AppKit
import QuartzCore

/// Full-screen, click-through, transparent window that draws the pointer ring and a
/// metrics line. The ring is animated by a display link at the screen's refresh rate
/// (120Hz on ProMotion), so motion looks smooth even though the camera gives 30 positions/s.
final class OverlayController: NSObject {
    var showMetrics = true
    var snapper: Snapper?
    /// Called every display frame with the final pointer position (drives the real cursor).
    var onFrame: ((CGPoint, PointerState) -> Void)?
    /// Where the pointer is actually drawn right now, after smoothing and snapping. Clicks go here.
    private(set) var output: CGPoint?

    // Speed-adaptive smoothing: slow hand -> heavy smoothing (no wobble),
    // fast hand -> light smoothing (no lag). Speeds in px/s.
    static let tauSlow = 0.070
    static let tauFast = 0.014
    static let slowSpeed = 120.0
    static let fastSpeed = 900.0
    // Prediction only kicks in for clearly intentional motion. On a near-still hand the
    // velocity is mostly tremor, and extrapolating it was adding wobble.
    static let predictFrom = 250.0 // px/s
    static let predictFull = 700.0
    static let predictLead = 0.06  // s. Tracking trails your hand by ~150ms; this hides part of it on fast moves
    static let predictMaxPx = 60.0
    static let snapTau = 0.035     // glide onto a snap target instead of teleporting

    private let window: NSWindow
    private let dot = CAShapeLayer()
    private let hud = CATextLayer()
    private var link: CADisplayLink?

    private var latest: PointerState?
    private var shown: CGPoint?
    private var lastTick: CFTimeInterval?
    private var lastPinch: PinchState = .open
    private var ticks = 0
    private var tickWindowStart = CACurrentMediaTime()
    private(set) var renderFps = 0.0

    init(screen: NSScreen) {
        let size = screen.frame.size
        window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        super.init()
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .screenSaver
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let view = NSView(frame: NSRect(origin: .zero, size: size))
        view.wantsLayer = true
        window.contentView = view

        dot.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
        dot.lineWidth = 2
        dot.shadowColor = NSColor.black.cgColor
        dot.shadowOpacity = 0.35
        dot.shadowRadius = 4
        dot.shadowOffset = .zero
        dot.opacity = 0

        hud.frame = CGRect(x: 16, y: size.height - 64, width: 900, height: 22)
        hud.contentsScale = screen.backingScaleFactor
        hud.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        hud.fontSize = 12
        hud.foregroundColor = NSColor.white.cgColor
        hud.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        hud.cornerRadius = 6

        view.layer?.addSublayer(hud)
        view.layer?.addSublayer(dot)
        window.orderFrontRegardless()

        let l = view.displayLink(target: self, selector: #selector(tick(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        l.add(to: .main, forMode: .common)
        link = l
    }

    /// New camera-rate state from the engine.
    func render(_ s: PointerState) {
        let pinchChanged = s.pinch != lastPinch
        lastPinch = s.pinch
        latest = s

        if pinchChanged || s.holdingClick {
            // Click: jump straight to the exact spot, no smoothing or prediction.
            shown = s.position
            if pinchChanged && s.pinch == .pinched {
                output = snapper?.apply(s.position) ?? s.position
            } else if s.holdingClick, let o = output {
                output = o // stay exactly where the click landed
            }
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let pinched = s.pinch == .pinched
        let snapped = snapper?.current != nil
        let r: CGFloat = pinched ? 7 : (snapped ? 14 : 11)
        dot.path = CGPath(ellipseIn: CGRect(x: -r, y: -r, width: r * 2, height: r * 2), transform: nil)
        dot.fillColor = pinched
            ? NSColor.systemTeal.cgColor
            : NSColor.white.withAlphaComponent(snapped ? 0.30 : 0.18).cgColor

        hud.isHidden = !showMetrics
        if showMetrics {
            let m = s.metrics
            var parts = [
                String(format: " track %.0f fps", m.fps),
                String(format: "draw %.0f fps", renderFps),
                String(format: "latency %.0f ms", m.latencyMs),
                String(format: "vision %.1f ms", m.visionMs),
            ]
            parts.append(s.handVisible ? String(format: "jitter %.1f px", m.jitterFiltered) : "no hand")
            if let c = snapper?.current { parts.append("snap: \(c.role.replacingOccurrences(of: "AX", with: ""))") }
            if pinched { parts.append(s.holdingClick ? "click" : "drag") }
            if s.recording { parts.append("● REC") }
            hud.string = parts.joined(separator: " · ")
        }
        CATransaction.commit()
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        ticks += 1
        if now - tickWindowStart >= 1 {
            renderFps = Double(ticks) / (now - tickWindowStart)
            ticks = 0
            tickWindowStart = now
        }
        guard let s = latest else { return }
        let dt = min(now - (lastTick ?? now), 0.05)
        lastTick = now

        let speed = Double(hypot(s.velocity.dx, s.velocity.dy))
        let dragging = s.pinch == .pinched && !s.holdingClick

        // 1. Prediction, only for clear motion
        var target = s.position
        if !s.holdingClick, s.handVisible {
            let amount = Self.smoothstep(Self.predictFrom, Self.predictFull, speed)
            let age = min(max(now - s.frameTime, 0), 0.1)
            let lead = CGFloat(min(age, Self.predictLead) * amount)
            var dx = s.velocity.dx * lead
            var dy = s.velocity.dy * lead
            let len = hypot(dx, dy)
            let cap = CGFloat(Self.predictMaxPx)
            if len > cap {
                dx *= cap / len
                dy *= cap / len
            }
            target = CGPoint(x: s.position.x + dx, y: s.position.y + dy)
        }

        // 2. Speed-adaptive chase
        let f = Self.smoothstep(Self.slowSpeed, Self.fastSpeed, speed)
        let tau = Self.tauSlow + (Self.tauFast - Self.tauSlow) * f
        var p = shown ?? target
        if !s.holdingClick {
            let k = CGFloat(1 - exp(-dt / tau))
            p = CGPoint(x: p.x + (target.x - p.x) * k, y: p.y + (target.y - p.y) * k)
        }
        shown = p

        // 3. Snap onto nearby buttons (never while dragging, never while a click is held)
        var out = output ?? p
        if s.holdingClick {
            // pinned
        } else if dragging || !s.handVisible {
            snapper?.reset()
            out = p
        } else {
            let snapped = snapper?.apply(p) ?? p
            let k = CGFloat(1 - exp(-dt / Self.snapTau))
            out = CGPoint(x: out.x + (snapped.x - out.x) * k, y: out.y + (snapped.y - out.y) * k)
        }
        output = out

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.position = out
        dot.opacity = Float(s.visibility)
        CATransaction.commit()

        if s.handVisible { onFrame?(out, s) }
    }

    private static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
