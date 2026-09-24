import AVFoundation
import CoreGraphics
import Foundation
import QuartzCore

enum PointerAnchor: String, CaseIterable {
    case palm      // center of the 4 knuckles: steadiest, default
    case knuckle   // index knuckle only
    case fingertip // most direct, but jumps when you pinch
}

enum PointerMode: String {
    case direct   // pointer goes where your hand is (default)
    case trackpad // relative movement with acceleration
}

/// How much hand movement covers the whole screen, as a fraction of the camera's width.
enum Sensitivity: String, CaseIterable {
    case low, medium, high, max

    var boxWidth: Double {
        switch self {
        case .low: return 0.22
        case .medium: return 0.17
        case .high: return 0.13 // your hand used ~0.12 of the frame in run-20260923-235017
        case .max: return 0.10
        }
    }
}

struct PointerState {
    var position: CGPoint // AppKit screen coords, origin bottom-left
    var velocity: CGVector // px/s, for render-side prediction
    var frameTime: Double  // host-clock seconds of the camera frame
    var visibility: CGFloat
    var handVisible: Bool
    var pinch: PinchState
    var holdingClick: Bool // pinched but not dragging yet: pointer is pinned to the click spot
    var calibrating: Bool
    var filterEnabled: Bool
    var anchor: PointerAnchor
    var mode: PointerMode
    var recording: Bool
    var metrics: MetricsSnapshot
}

/// Camera frame -> hand landmarks -> filtered, stabilized screen pointer + pinch state.
/// Runs entirely on the camera queue. Change settings through `update {}`.
final class TrackingEngine {
    // --- Tracking loss ---
    static let minConfidence: Float = 0.3     // to KEEP tracking a hand
    static let acquireConfidence: Float = 0.5 // to START tracking one. Log 20260924-001302 had
                                              // 0.32-0.46 "hands" that vanished after 1 frame and threw the pointer
    static let pinchArmDelay = 0.2   // s after a hand appears before it can click (a hand entering
                                     // the frame often looks like a pinch: 4 false clicks in that log)
    static let maxJumpPerSec = 2.5   // camera-widths/s. Faster than this = a landmark glitch, not your hand
                                     // (those caused the 500-1300px "drags" in that log)
    static let coastDuration = 0.15 // s: short dropouts are ignored
    static let fadeDuration = 0.35  // s: then fade out and release the pinch
    static let resetAfterLost = 0.3 // s: after this, filters restart

    // --- Smoothing (camera space, before mapping to the screen) ---
    static let minCutoff = 0.8
    static let beta = 40.0

    // --- Stabilization (screen px, after mapping) ---
    static let bandPx = 6.0          // wobble smaller than this is ignored; beyond it the pointer follows exactly
    static let lockSpeedPx = 40.0    // pointer slower than this (px/s)...
    static let lockAfterStill = 0.15 // ...for this long locks in place
    static let lockRadiusPx = 14.0   // and unlocks once your hand clearly moves

    // --- Clicking ---
    // When the pinch lands, the pointer snaps back to where it was just before your fingers
    // started closing (the hand always drifts a bit while pinching). It then stays pinned
    // there until you move past dragStartPx, so a click never turns into an accidental drag.
    static let openRatio = 0.22      // fingers "open" above this: the aim point is taken from here
    static let rewindMax = 0.4       // s: never rewind further back than this
    static let rewindMaxPx = 45.0    // moving fast while pinching = starting a drag, don't snap back
    static let dragStartPx = 40.0    // hand must move this far from where the pinch landed
    static let dragMinHold = 0.25    // ...and the pinch must be this old. Quick taps are always clicks:
                                     // in log 20260924-004426 your clicks lasted 67-300ms, and the pinch
                                     // itself jerked the palm 40-130px, turning 18 of 44 into drags
    static let dragFastPx = 150.0    // a big, clear pull starts a drag right away
    static let nearMissBelow = 0.16  // fingers got this close but no click -> logged as a near miss

    // --- Trackpad mode ---
    static let padDeadSpeed = 0.02
    static let padSlowSpeed = 0.05
    static let padFastSpeed = 0.35
    static let padGainSlow = 1.5
    static let padGainFast = 8.0

    var filterEnabled = true
    var anchor: PointerAnchor = .palm
    var mode: PointerMode = .direct
    var sensitivity: Sensitivity = .high
    var onUpdate: ((PointerState) -> Void)?

    private let queue: DispatchQueue
    private let screenSize: CGSize
    private let tracker = HandTracker()
    private let metrics = Metrics()
    private let recorder = RunRecorder()
    private let perf = PerfWindow()

    private var ax = OneEuroFilter(minCutoff: TrackingEngine.minCutoff, beta: TrackingEngine.beta)
    private var ay = OneEuroFilter(minCutoff: TrackingEngine.minCutoff, beta: TrackingEngine.beta)
    private var pinch = PinchDetector()

    private var position: CGPoint
    private var velocity = CGVector.zero
    private var box: CGRect?           // direct mode: camera region mapped onto the screen
    private var padVirtual: CGPoint?   // trackpad mode: integrated position before stabilization
    private var lastFiltered: CGPoint?
    private var lastT: Double?
    private var stillSince: Double?
    private var locked = false
    private var lockedAt: Double?
    private var lostSince: Double?

    // Pinch scale without the wrist: learn palmLength / knuckleSpan while the wrist is visible,
    // then use knuckleSpan * that factor when it isn't. Keeps the same thresholds either way.
    private var spanToPalm = 1.6
    private var history: [(t: Double, pos: CGPoint, ratio: Double)] = []
    private var clickSpot: CGPoint?   // non-nil while pinched and still within dragStartPx
    private var nearMissMin: Double?  // lowest ratio in the current "fingers close" episode

    // Log-only state (so we log transitions, not every frame)
    private var handShownSince: Double?
    private var reportedLost = true
    private var pinchDown: (t: Double, pos: CGPoint, rewindMs: Int, rewindPx: Double)?

    init(screenSize: CGSize, queue: DispatchQueue) {
        self.screenSize = screenSize
        self.queue = queue
        position = CGPoint(x: screenSize.width / 2, y: screenSize.height / 2)
    }

    func update(_ change: @escaping (TrackingEngine) -> Void) {
        queue.async { change(self) }
    }

    func noteDroppedFrame() {
        perf.droppedByCamera += 1
    }

    // MARK: - Per frame

    func process(_ sampleBuffer: CMSampleBuffer) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            logWarn("camera", "frame_without_image")
            return
        }
        // Camera timestamps are on the host clock, so "now - t" is capture-to-here latency.
        let t = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        let cameraMs = (CMClockGetTime(CMClockGetHostTimeClock()).seconds - t) * 1000

        let visionStart = CACurrentMediaTime()
        let hand = tracker.detect(pixels)
        let visionMs = (CACurrentMediaTime() - visionStart) * 1000

        let previous = position
        var raw = position
        var cam = CGPoint(x: -1, y: -1)
        var visibility: CGFloat = 1
        var visible = false
        var ratio = Double.nan
        var pinchSource = ""

        if let hand,
           hand.pointerConfidence >= (reportedLost ? Self.acquireConfidence : Self.minConfidence),
           !isGlitch(hand, t: t) {
            visible = true
            if reportedLost {
                logInfo("hand", "acquired", [
                    "after_ms": ms(t - (lostSince ?? t)),
                    "pointer_conf": hand.pointerConfidence,
                    "pinch_conf": hand.pinchConfidence,
                    "wrist_conf": hand.wristConfidence,
                ])
                reportedLost = false
                handShownSince = t
            } else if let lost = lostSince {
                logDebug("hand", "dropout_bridged", ["ms": ms(t - lost)])
            }
            if let lost = lostSince, t - lost > Self.resetAfterLost { resetFilters(reason: "reacquired") }
            lostSince = nil

            cam = mirrored(anchorPoint(hand))
            lastCam = (cam, t)
            if hand.pinchConfidence >= Self.minConfidence {
                (ratio, pinchSource) = pinchRatio(hand)
            }

            let f = filterEnabled
                ? CGPoint(x: ax.filter(Double(cam.x), t: t), y: ay.filter(Double(cam.y), t: t))
                : cam

            let target: CGPoint
            switch mode {
            case .direct:
                let r = directTargets(raw: cam, filtered: f)
                raw = r.0
                target = r.1
            case .trackpad:
                target = trackpadTarget(filtered: f, t: t)
                raw = target
            }
            let moved = filterEnabled ? stabilize(target, t: t) : target
            lastFiltered = f
            lastT = t

            let armed = t - (handShownSince ?? t) >= Self.pinchArmDelay || pinch.state == .pinched
            if !ratio.isNaN, armed {
                let before = pinch.state
                let after = pinch.update(ratio: ratio)
                if before == .open, after == .pinched {
                    let aim = aimPoint(at: t, fallback: position)
                    clickSpot = distance(aim, moved) <= Self.rewindMaxPx ? aim : moved
                    // Drag distance is measured from where the HAND was at pinch time, not from the
                    // rewound aim point. Measuring from the aim point started 28 of 40 clicks as
                    // drags instantly in log 20260924-002140.
                    dragOrigin = moved
                    logPinch(.pinched, ratio: ratio, t: t, reason: "fingers", current: moved)
                } else if before == .pinched, after == .open {
                    logPinch(.open, ratio: ratio, t: t, reason: "fingers", current: moved)
                    clickSpot = nil
                }
                trackNearMiss(ratio: ratio)
            }

            if let spot = clickSpot {
                let pull = distance(moved, dragOrigin ?? spot)
                let age = t - (pinchDown?.t ?? t)
                if (pull > Self.dragStartPx && age >= Self.dragMinHold) || pull > Self.dragFastPx {
                    logDebug("gesture", "drag_start", ["from": spot, "held_ms": ms(age), "pull_px": pull])
                    clickSpot = nil
                    // Carry the offset between the click spot and the hand so the drag starts
                    // exactly at the click spot instead of jumping to the hand position.
                    let o = dragOrigin ?? spot
                    offset = CGVector(dx: spot.x - o.x, dy: spot.y - o.y)
                    position = CGPoint(x: moved.x + offset.dx, y: moved.y + offset.dy)
                } else {
                    position = spot
                }
            } else {
                if pinch.state == .open {
                    // Fade the drag offset out after release so the pointer eases back onto the hand
                    offset = CGVector(dx: offset.dx * 0.8, dy: offset.dy * 0.8)
                    if abs(offset.dx) + abs(offset.dy) < 0.5 { offset = .zero }
                }
                position = CGPoint(x: moved.x + offset.dx, y: moved.y + offset.dy)
            }

            history.append((t, position, ratio))
            while let first = history.first, t - first.t > Self.rewindMax { history.removeFirst() }
        } else {
            if lostSince == nil { lostSince = t }
            let lostFor = t - (lostSince ?? t)
            if lostFor > Self.coastDuration {
                if !reportedLost {
                    let shownFor = (lostSince ?? t) - (handShownSince ?? (lostSince ?? t))
                    logInfo("hand", "lost", [
                        "visible_ms": ms(shownFor),
                        "last_conf": hand?.pointerConfidence ?? -1, // -1 = no hand detected at all
                    ])
                    reportedLost = true
                    perf.noteHandLost()
                }
                if pinch.state == .pinched { logPinch(.open, ratio: .nan, t: t, reason: "hand_lost", current: position) }
                // Real loss: fade out in place and release. Never teleport, never stay grabbed.
                visibility = CGFloat(max(0, 1 - (lostFor - Self.coastDuration) / Self.fadeDuration))
                pinch.reset()
                clickSpot = nil
                history.removeAll()
            }
        }

        // Velocity for the render loop's prediction. Zero while pinned so it never drifts off a click.
        if let prevT = lastVelocityT, t > prevT, visible, clickSpot == nil, !locked {
            let dt = CGFloat(t - prevT)
            let v = CGVector(dx: (position.x - previous.x) / dt, dy: (position.y - previous.y) / dt)
            velocity = CGVector(dx: velocity.dx * 0.5 + v.dx * 0.5, dy: velocity.dy * 0.5 + v.dy * 0.5)
        } else {
            velocity = .zero
        }
        lastVelocityT = t

        let latencyMs = (CMClockGetTime(CMClockGetHostTimeClock()).seconds - t) * 1000
        let snap = metrics.record(
            t: t, visionMs: visionMs, latencyMs: latencyMs,
            raw: visible ? raw : nil, filtered: visible ? position : nil
        )

        let onEdge = position.x <= 0.5 || position.y <= 0.5
            || position.x >= screenSize.width - 0.5 || position.y >= screenSize.height - 0.5
        perf.add(latencyMs: latencyMs, visionMs: visionMs, cameraMs: cameraMs, visible: visible,
                 frozen: clickSpot != nil, locked: locked, onEdge: visible && onEdge)
        if var summary = perf.flushIfDue(t) {
            summary["mode"] = mode.rawValue
            summary["sensitivity"] = sensitivity.rawValue
            summary["span_to_palm"] = spanToPalm
            logInfo("perf", "summary", summary)
            if let p95 = summary["latency_p95_ms"] as? Double, p95 > 200 {
                logWarn("perf", "latency_high", ["p95_ms": p95, "thermal": ProcessInfo.processInfo.thermalState.rawValue])
            }
        }

        if recorder.isRecording {
            let fields: [String] = [
                String(format: "%.4f", t),
                visible ? "1" : "0",
                String(format: "%.2f", Double(raw.x)),
                String(format: "%.2f", Double(raw.y)),
                String(format: "%.2f", Double(position.x)),
                String(format: "%.2f", Double(position.y)),
                ratio.isNaN ? "" : String(format: "%.3f", ratio),
                pinch.state == .pinched ? "1" : "0",
                String(format: "%.2f", visionMs),
                String(format: "%.2f", latencyMs),
                filterEnabled ? "1" : "0",
                anchor.rawValue,
                mode.rawValue,
                String(format: "%.4f", Double(cam.x)),
                String(format: "%.4f", Double(cam.y)),
                sensitivity.rawValue,
                pinchSource,
            ]
            recorder.write(fields.joined(separator: ","))
        }

        onUpdate?(PointerState(
            position: position,
            velocity: velocity,
            frameTime: t,
            visibility: visibility,
            handVisible: visible,
            pinch: pinch.state,
            holdingClick: clickSpot != nil,
            calibrating: false,
            filterEnabled: filterEnabled,
            anchor: anchor,
            mode: mode,
            recording: recorder.isRecording,
            metrics: snap
        ))
    }

    private var lastVelocityT: Double?
    private var edgePushing = false
    private var lastCam: (p: CGPoint, t: Double)?
    private var dragOrigin: CGPoint?
    private var offset = CGVector.zero
    private lazy var stable: CGPoint = position // stabilizer state, kept apart from the output (which may carry a drag offset)
    private var glitches = 0

    /// A single-frame landmark jump that no real hand could make. Treated like a dropout.
    private func isGlitch(_ h: HandSample, t: Double) -> Bool {
        guard let last = lastCam, t > last.t, t - last.t < 0.2 else { return false }
        let speed = distance(mirrored(anchorPoint(h)), last.p) / (t - last.t)
        guard speed > Self.maxJumpPerSec else { return false }
        glitches += 1
        if glitches <= 5 || glitches % 50 == 0 {
            logDebug("hand", "glitch_rejected", ["speed": speed, "count": glitches, "pinched": pinch.state == .pinched])
        }
        return true
    }

    // MARK: - Pinch

    private func pinchRatio(_ h: HandSample) -> (Double, String) {
        let span = h.knuckleSpan
        if h.wristConfidence >= 0.5, span > 0, h.palmLength > 0 {
            let observed = h.palmLength / span
            spanToPalm = min(max(spanToPalm + 0.05 * (observed - spanToPalm), 1.0), 2.5)
            return (h.fingerGap / h.palmLength, "wrist")
        }
        guard span > 0 else { return (.nan, "") }
        return (h.fingerGap / (span * spanToPalm), "knuckles")
    }

    /// Where the pointer was right before the fingers started closing.
    private func aimPoint(at t: Double, fallback: CGPoint) -> CGPoint {
        for h in history.reversed() where !h.ratio.isNaN && h.ratio >= Self.openRatio {
            return h.pos
        }
        return history.first?.pos ?? fallback
    }

    private func trackNearMiss(ratio: Double) {
        if pinch.state == .pinched {
            nearMissMin = nil
            return
        }
        if ratio < Self.nearMissBelow {
            nearMissMin = min(nearMissMin ?? ratio, ratio)
        } else if ratio > Self.openRatio, let m = nearMissMin {
            // Fingers came close and opened again without a click
            logInfo("gesture", "near_miss", ["min_ratio": m, "enter_below": pinch.enterBelow, "instant_below": pinch.instantBelow])
            nearMissMin = nil
        }
    }

    private func logPinch(_ state: PinchState, ratio: Double, t: Double, reason: String, current: CGPoint) {
        switch state {
        case .pinched:
            let spot = clickSpot ?? current
            let rewindFrom = history.last(where: { !$0.ratio.isNaN && $0.ratio >= Self.openRatio })?.t
            let rewindMs = rewindFrom.map { ms(t - $0) } ?? -1
            let rewindPx = distance(current, spot)
            pinchDown = (t, spot, rewindMs, rewindPx)
            perf.notePinchDown()
            logInfo("gesture", "pinch_down", [
                "ratio": ratio, "pos": spot, "rewind_ms": rewindMs, "rewind_px": rewindPx,
            ])
        case .open:
            let held = pinchDown.map { ms(t - $0.t) } ?? 0
            let moved = pinchDown.map { distance($0.pos, current) } ?? 0
            logInfo("gesture", "pinch_up", [
                "reason": reason, "ratio": ratio, "held_ms": held, "dragged_px": moved,
                "was_drag": clickSpot == nil, "pos": current,
            ])
            pinchDown = nil
        }
    }

    // MARK: - Direct mode

    /// A small box in camera space maps onto the whole screen. No calibration step:
    /// if your hand goes past an edge, the box slides along with it, so the pointer never
    /// gets stuck at a screen edge and you never have to "reach back".
    private func directTargets(raw cam: CGPoint, filtered f: CGPoint) -> (CGPoint, CGPoint) {
        let bw = CGFloat(sensitivity.boxWidth)
        let bh = bw * (screenSize.height / screenSize.width) * (4.0 / 3.0) // camera frame is 4:3

        var b = box ?? .zero
        if box == nil || b.width != bw {
            logDebug("pointer", "box_placed", [
                "reason": box == nil ? "start" : "sensitivity",
                "hand": f, "pointer": position, "box_w": Double(bw),
            ])
            // Place the box so the hand maps to where the pointer already is: no jump.
            b = CGRect(
                x: f.x - bw * position.x / screenSize.width,
                y: f.y - bh * position.y / screenSize.height,
                width: bw, height: bh
            )
        }
        let before = b.origin
        if f.x < b.minX { b.origin.x = f.x }
        if f.x > b.maxX { b.origin.x = f.x - bw }
        if f.y < b.minY { b.origin.y = f.y }
        if f.y > b.maxY { b.origin.y = f.y - bh }
        let pushing = b.origin != before
        if pushing && !edgePushing {
            logDebug("pointer", "edge_push", ["dx": Double(b.origin.x - before.x), "dy": Double(b.origin.y - before.y)])
        }
        edgePushing = pushing
        box = b

        func map(_ p: CGPoint) -> CGPoint {
            CGPoint(
                x: min(max((p.x - b.minX) / bw, 0), 1) * screenSize.width,
                y: min(max((p.y - b.minY) / bh, 0), 1) * screenSize.height
            )
        }
        return (map(cam), map(f))
    }

    // MARK: - Trackpad mode

    private func trackpadTarget(filtered f: CGPoint, t: Double) -> CGPoint {
        guard let prev = lastFiltered, let prevT = lastT, t > prevT else {
            padVirtual = position
            return position
        }
        let dx = f.x - prev.x
        let dy = f.y - prev.y
        let speed = Double(hypot(dx, dy)) / (t - prevT)
        let gain = CGFloat(Self.padGain(speed: speed)) * screenSize.width
        let v = padVirtual ?? position
        let next = CGPoint(
            x: min(max(v.x + dx * gain, 0), screenSize.width),
            y: min(max(v.y + dy * gain, 0), screenSize.height)
        )
        padVirtual = next
        return next
    }

    static func padGain(speed v: Double) -> Double {
        let still = smoothstep(padDeadSpeed, padDeadSpeed * 2, v)
        let fast = smoothstep(padSlowSpeed, padFastSpeed, v)
        return still * (padGainSlow + (padGainFast - padGainSlow) * fast)
    }

    private static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    // MARK: - Stabilization

    /// 1. Still-lock: after a short pause the pointer pins in place until the hand clearly moves.
    /// 2. Rubber band: the pointer ignores wobble smaller than `bandPx`, and beyond that follows
    ///    the target exactly (always trailing by a constant few px, so no growing lag).
    private func stabilize(_ target: CGPoint, t: Double) -> CGPoint {
        let dt = max(t - (lastT ?? t), 1e-3)

        if locked {
            let pull = distance(target, stable)
            if pull < Self.lockRadiusPx { return stable }
            logDebug("pointer", "lock_off", ["held_ms": ms(t - (lockedAt ?? t)), "pull_px": pull])
            locked = false
            lockedAt = nil
            stillSince = nil
        }

        var p = stable
        let d = distance(target, p)
        if d > Self.bandPx {
            let k = CGFloat((d - Self.bandPx) / d)
            p = CGPoint(x: p.x + (target.x - p.x) * k, y: p.y + (target.y - p.y) * k)
        }

        let speed = distance(p, stable) / dt
        stable = p
        if speed < Self.lockSpeedPx {
            if stillSince == nil { stillSince = t }
            if let s = stillSince, t - s >= Self.lockAfterStill {
                locked = true
                lockedAt = t
                logDebug("pointer", "lock_on", ["pos": p])
            }
        } else {
            stillSince = nil
        }
        return p
    }

    // MARK: - Controls (call via update {})

    private func anchorPoint(_ h: HandSample) -> CGPoint {
        switch anchor {
        case .palm: return h.palm
        case .knuckle: return h.indexMCP
        case .fingertip: return h.indexTip
        }
    }

    func resetFilters(reason: String = "setting_changed") {
        logDebug("pointer", "reset", ["reason": reason])
        if pinch.state == .pinched { logPinch(.open, ratio: .nan, t: lastT ?? 0, reason: "reset", current: position) }
        ax.reset()
        ay.reset()
        lastFiltered = nil
        lastT = nil
        padVirtual = nil
        stillSince = nil
        locked = false
        lockedAt = nil
        box = nil
        clickSpot = nil
        dragOrigin = nil
        offset = .zero
        stable = position
        nearMissMin = nil
        history.removeAll()
        pinch.reset()
    }

    /// Returns the CSV path when a recording starts, nil when it stops.
    func toggleRecording() -> URL? {
        if recorder.isRecording {
            logInfo("recorder", "stopped", ["file": recorder.url?.lastPathComponent ?? ""])
            recorder.stop()
            return nil
        }
        do {
            try recorder.start(note: "\(mode.rawValue)-\(sensitivity.rawValue)-\(anchor.rawValue)")
            logInfo("recorder", "started", ["file": recorder.url?.path ?? ""])
        } catch {
            logError("recorder", "start_failed", ["error": "\(error)"])
        }
        return recorder.url
    }

    /// Camera image isn't mirrored, so moving your hand right moves it left in the frame.
    private func mirrored(_ p: CGPoint) -> CGPoint {
        CGPoint(x: 1 - p.x, y: p.y)
    }
}
