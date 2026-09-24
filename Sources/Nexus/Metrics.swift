import CoreGraphics
import Foundation

struct MetricsSnapshot {
    var fps = 0.0
    var visionMs = 0.0
    var latencyMs = 0.0      // camera capture timestamp -> pointer position computed
    var jitterRaw = 0.0      // RMS spread of the last ~0.5s, in px. Only meaningful while holding still.
    var jitterFiltered = 0.0
}

final class Metrics {
    private var snap = MetricsSnapshot()
    private var lastT: Double?
    private var rawWindow: [CGPoint] = []
    private var filteredWindow: [CGPoint] = []
    private let windowSize = 15
    private let smoothing = 0.1

    func record(t: Double, visionMs: Double, latencyMs: Double, raw: CGPoint?, filtered: CGPoint?) -> MetricsSnapshot {
        if let lastT, t > lastT { snap.fps = ema(snap.fps, 1 / (t - lastT)) }
        lastT = t
        snap.visionMs = ema(snap.visionMs, visionMs)
        snap.latencyMs = ema(snap.latencyMs, latencyMs)

        if let raw, let filtered {
            push(raw, into: &rawWindow)
            push(filtered, into: &filteredWindow)
        } else {
            rawWindow.removeAll()
            filteredWindow.removeAll()
        }
        snap.jitterRaw = Self.rms(rawWindow)
        snap.jitterFiltered = Self.rms(filteredWindow)
        return snap
    }

    private func ema(_ old: Double, _ new: Double) -> Double {
        old == 0 ? new : old + smoothing * (new - old)
    }

    private func push(_ p: CGPoint, into window: inout [CGPoint]) {
        window.append(p)
        if window.count > windowSize { window.removeFirst() }
    }

    private static func rms(_ pts: [CGPoint]) -> Double {
        guard pts.count > 2 else { return 0 }
        let n = CGFloat(pts.count)
        let mx = pts.reduce(0) { $0 + $1.x } / n
        let my = pts.reduce(0) { $0 + $1.y } / n
        let sq = pts.reduce(0) { $0 + pow($1.x - mx, 2) + pow($1.y - my, 2) }
        return sqrt(Double(sq / n))
    }
}

/// Writes one CSV row per frame to ./runs/ so every claim about smoothness or
/// latency can be backed by a file in the repo.
final class RunRecorder {
    private var handle: FileHandle?
    private(set) var url: URL?
    var isRecording: Bool { handle != nil }

    static let header = "t,hand,raw_x,raw_y,x,y,pinch_ratio,pinched,vision_ms,latency_ms,filter,anchor,mode,cam_x,cam_y,sensitivity,pinch_src"

    func start(note: String) throws {
        let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("runs")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let file = dir.appendingPathComponent("run-\(f.string(from: Date()))-\(note).csv")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        handle = try FileHandle(forWritingTo: file)
        url = file
        write(Self.header)
    }

    func write(_ line: String) {
        handle?.write(Data((line + "\n").utf8))
    }

    func stop() {
        try? handle?.close()
        handle = nil
    }
}
