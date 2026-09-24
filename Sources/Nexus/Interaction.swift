import CoreGraphics
import Foundation

// MARK: - One Euro filter
// Casiez et al., CHI 2012. Low-pass whose cutoff rises with speed:
// heavy smoothing when the hand is almost still (kills jitter),
// light smoothing when it moves fast (kills lag).

private struct LowPass {
    var value: Double?
    mutating func filter(_ x: Double, alpha: Double) -> Double {
        let y = value.map { alpha * x + (1 - alpha) * $0 } ?? x
        value = y
        return y
    }
}

struct OneEuroFilter {
    let minCutoff: Double
    let beta: Double
    let dCutoff: Double = 1.0

    private var x = LowPass()
    private var dx = LowPass()
    private var lastT: Double?

    init(minCutoff: Double, beta: Double) {
        self.minCutoff = minCutoff
        self.beta = beta
    }

    private static func alpha(cutoff: Double, dt: Double) -> Double {
        let tau = 1 / (2 * Double.pi * cutoff)
        return 1 / (1 + tau / dt)
    }

    mutating func filter(_ value: Double, t: Double) -> Double {
        guard let lastT, let prev = x.value else {
            self.lastT = t
            return x.filter(value, alpha: 1)
        }
        let dt = t - lastT
        guard dt > 0 else { return prev }
        self.lastT = t

        let speed = dx.filter((value - prev) / dt, alpha: Self.alpha(cutoff: dCutoff, dt: dt))
        let cutoff = minCutoff + beta * abs(speed)
        return x.filter(value, alpha: Self.alpha(cutoff: cutoff, dt: dt))
    }

    mutating func reset() {
        x = LowPass()
        dx = LowPass()
        lastT = nil
    }
}

// MARK: - Pinch with hysteresis
// Two thresholds (close to enter, wider to exit) + a minimum number of frames,
// so the state doesn't flicker when the fingers hover near the threshold.

enum PinchState { case open, pinched }

struct PinchDetector {
    // From run-20260923-235455: real touches bottom out at 0.06-0.13. 11 of 25 approaches
    // were missed, several with ratio 0.08-0.11 for a single frame (the old rule needed 2).
    // Log 20260924-004426: 5 near misses bottomed out at 0.107-0.126, just above the old 0.10 /
    // 0.13 thresholds. Nudged up slightly; open fingers still sit at 0.2+.
    var instantBelow = 0.115 // one frame this close = definitely touching
    var enterBelow = 0.14    // or two frames in a row this close
    var exitAbove = 0.19
    var framesToExit = 2    // one noisy frame won't drop you mid-drag

    private(set) var state: PinchState = .open
    private var candidateFrames = 0
    private var exitFrames = 0

    mutating func update(ratio: Double) -> PinchState {
        switch state {
        case .open:
            if ratio < instantBelow {
                state = .pinched
                candidateFrames = 0
            } else if ratio < enterBelow {
                candidateFrames += 1
                if candidateFrames >= 2 {
                    state = .pinched
                    candidateFrames = 0
                }
            } else {
                candidateFrames = 0
            }
        case .pinched:
            if ratio > exitAbove {
                exitFrames += 1
                if exitFrames >= framesToExit {
                    state = .open
                    exitFrames = 0
                }
            } else {
                exitFrames = 0
            }
        }
        return state
    }

    mutating func reset() {
        state = .open
        candidateFrames = 0
        exitFrames = 0
    }
}

// MARK: - Calibration
// Maps the region your hand comfortably covers (in camera space) onto the whole screen,
// so you don't have to stretch your arm to reach the corners.

struct Calibration: Codable {
    var minX: CGFloat = 0.20
    var maxX: CGFloat = 0.80
    var minY: CGFloat = 0.25
    var maxY: CGFloat = 0.85

    func map(_ p: CGPoint, to size: CGSize) -> CGPoint {
        let nx = min(max((p.x - minX) / (maxX - minX), 0), 1)
        let ny = min(max((p.y - minY) / (maxY - minY), 0), 1)
        return CGPoint(x: nx * size.width, y: ny * size.height)
    }

    /// 5th-95th percentile of a hand sweep, so one stray detection doesn't stretch the box.
    static func fit(_ samples: [CGPoint]) -> Calibration? {
        guard samples.count > 30 else { return nil }
        let xs = samples.map(\.x).sorted()
        let ys = samples.map(\.y).sorted()
        func pct(_ a: [CGFloat], _ p: Double) -> CGFloat { a[Int(Double(a.count - 1) * p)] }
        let c = Calibration(minX: pct(xs, 0.05), maxX: pct(xs, 0.95), minY: pct(ys, 0.05), maxY: pct(ys, 0.95))
        guard c.maxX - c.minX > 0.1, c.maxY - c.minY > 0.1 else { return nil } // sweep was too small
        return c
    }

    private static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nexus/calibration.json")
    }

    static func load() -> Calibration {
        guard let data = try? Data(contentsOf: url),
              let c = try? JSONDecoder().decode(Calibration.self, from: data)
        else { return Calibration() }
        return c
    }

    func save() {
        try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(self).write(to: Self.url)
    }
}
