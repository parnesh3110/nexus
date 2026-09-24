import CoreGraphics
import Foundation
import os
import QuartzCore

// MARK: - Logger
//
// Every run writes one JSON-lines file to ./logs/nexus-<timestamp>.log
// - file: everything, including debug events
// - terminal: info and above (set NEXUS_LOG=debug to see debug too)
// - Console.app: info and above, subsystem "dev.parnesh.nexus"
//
// Convention for every phase: log state TRANSITIONS (acquired/lost, pinch down/up,
// lock on/off, wake word heard, request sent/answered), never per-frame values.
// Per-frame numbers go in the CSV recorder; a 5s perf summary goes here.

enum LogLevel: Int, Comparable {
    case debug, info, warn, error

    var name: String {
        switch self {
        case .debug: return "debug"
        case .info: return "info"
        case .warn: return "warn"
        case .error: return "error"
        }
    }

    static func < (a: LogLevel, b: LogLevel) -> Bool { a.rawValue < b.rawValue }
}

final class Log {
    static let shared = Log()

    private(set) var url: URL?
    private let queue = DispatchQueue(label: "nexus.log", qos: .utility)
    private var handle: FileHandle?
    private let consoleLevel: LogLevel
    private let osLog = Logger(subsystem: "dev.parnesh.nexus", category: "nexus")
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private init() {
        consoleLevel = ProcessInfo.processInfo.environment["NEXUS_LOG"] == "debug" ? .debug : .info
        let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("logs")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd-HHmmss"
            let file = dir.appendingPathComponent("nexus-\(f.string(from: Date())).log")
            FileManager.default.createFile(atPath: file.path, contents: nil)
            handle = try FileHandle(forWritingTo: file)
            url = file
        } catch {
            print("logging to file disabled: \(error)")
        }
    }

    func write(_ level: LogLevel, _ category: String, _ event: String, _ fields: [String: Any]) {
        let now = Date()
        queue.async { [self] in
            var obj: [String: Any] = ["ts": iso.string(from: now), "lvl": level.name, "cat": category, "event": event]
            for (k, v) in fields { obj[k] = Self.clean(v) }

            if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) {
                handle?.write(data)
                handle?.write(Data("\n".utf8))
            }

            guard level >= consoleLevel else { return }
            let extras = fields.keys.sorted().map { "\($0)=\(Self.short(Self.clean(fields[$0]!)))" }.joined(separator: " ")
            let line = "\(clock.string(from: now)) \(level.name.uppercased()) \(category).\(event) \(extras)"
            print(line)
            switch level {
            case .error: osLog.error("\(line, privacy: .public)")
            case .warn: osLog.warning("\(line, privacy: .public)")
            default: osLog.info("\(line, privacy: .public)")
            }
        }
    }

    /// Blocks until everything queued is on disk. Use before the process dies.
    func flush() {
        queue.sync { try? handle?.synchronize() }
    }

    private static func clean(_ v: Any) -> Any {
        switch v {
        case let d as Double: return d.isFinite ? (d * 1000).rounded() / 1000 : NSNull()
        case let f as Float: return clean(Double(f))
        case let c as CGFloat: return clean(Double(c))
        case let b as Bool: return b
        case let i as Int: return i
        case let s as String: return s
        case let p as CGPoint: return [clean(p.x), clean(p.y)]
        case let a as [Any]: return a.map(clean)
        case let d as [String: Any]: return d.mapValues(clean)
        default: return String(describing: v)
        }
    }

    private static func short(_ v: Any) -> String {
        if let a = v as? [Any] { return "[" + a.map(short).joined(separator: ",") + "]" }
        if v is NSNull { return "nan" }
        return "\(v)"
    }
}

func logDebug(_ cat: String, _ event: String, _ fields: [String: Any] = [:]) { Log.shared.write(.debug, cat, event, fields) }
func logInfo(_ cat: String, _ event: String, _ fields: [String: Any] = [:]) { Log.shared.write(.info, cat, event, fields) }
func logWarn(_ cat: String, _ event: String, _ fields: [String: Any] = [:]) { Log.shared.write(.warn, cat, event, fields) }
func logError(_ cat: String, _ event: String, _ fields: [String: Any] = [:]) { Log.shared.write(.error, cat, event, fields) }

/// Seconds -> whole milliseconds, for log fields.
func ms(_ seconds: Double) -> Int { Int((seconds * 1000).rounded()) }

// MARK: - Perf summary (logged every 5s)

final class PerfWindow {
    let interval = 5.0
    var droppedByCamera = 0

    private var start: Double?
    private var frames = 0
    private var handFrames = 0
    private var frozenFrames = 0
    private var lockedFrames = 0
    private var edgeFrames = 0
    private var pinchDowns = 0
    private var handLosses = 0
    private var latency: [Double] = []
    private var vision: [Double] = []
    private var camera: [Double] = []
    private var lastCPU = cpuSeconds()
    private var lastWall = CACurrentMediaTime()

    func add(latencyMs: Double, visionMs: Double, cameraMs: Double, visible: Bool, frozen: Bool, locked: Bool, onEdge: Bool) {
        frames += 1
        latency.append(latencyMs)
        vision.append(visionMs)
        camera.append(cameraMs)
        if visible { handFrames += 1 }
        if frozen { frozenFrames += 1 }
        if locked { lockedFrames += 1 }
        if onEdge { edgeFrames += 1 }
    }

    func notePinchDown() { pinchDowns += 1 }
    func noteHandLost() { handLosses += 1 }

    /// Returns summary fields once per `interval`, nil otherwise.
    func flushIfDue(_ t: Double) -> [String: Any]? {
        guard let s = start else { start = t; return nil }
        guard t - s >= interval, frames > 0 else { return nil }

        let wall = CACurrentMediaTime()
        let cpu = cpuSeconds()
        let pct = { (n: Int) in Int((Double(n) / Double(max(self.handFrames, 1)) * 100).rounded()) }
        let summary: [String: Any] = [
            "fps": Double(frames) / (t - s),
            "hand_pct": Int((Double(handFrames) / Double(frames) * 100).rounded()),
            "latency_p50_ms": percentile(latency, 50),
            "latency_p95_ms": percentile(latency, 95),
            "vision_p50_ms": percentile(vision, 50),
            "vision_p95_ms": percentile(vision, 95),
            // capture -> frame reaches our code. Everything above this is the camera + macOS, not us.
            "camera_p50_ms": percentile(camera, 50),
            "frozen_pct": pct(frozenFrames),
            "locked_pct": pct(lockedFrames),
            "edge_pct": pct(edgeFrames),
            "pinch_downs": pinchDowns,
            "hand_losses": handLosses,
            "camera_dropped": droppedByCamera,
            "cpu_pct": (cpu - lastCPU) / max(wall - lastWall, 1e-3) * 100,
            "rss_mb": residentMB(),
        ]

        start = t
        frames = 0; handFrames = 0; frozenFrames = 0; lockedFrames = 0; edgeFrames = 0
        pinchDowns = 0; handLosses = 0; droppedByCamera = 0
        latency.removeAll(keepingCapacity: true)
        vision.removeAll(keepingCapacity: true)
        camera.removeAll(keepingCapacity: true)
        lastCPU = cpu
        lastWall = wall
        return summary
    }
}

func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return .nan }
    let s = values.sorted()
    return s[min(s.count - 1, Int(Double(s.count - 1) * p / 100))]
}

func cpuSeconds() -> Double {
    var u = rusage()
    getrusage(RUSAGE_SELF, &u)
    return Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec) / 1e6
        + Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec) / 1e6
}

func residentMB() -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1
}

// MARK: - Environment info for the start-of-run log line

func systemInfo() -> [String: Any] {
    var size = 0
    sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
    var chip = [CChar](repeating: 0, count: max(size, 1))
    sysctlbyname("machdep.cpu.brand_string", &chip, &size, nil, 0)

    return [
        "os": ProcessInfo.processInfo.operatingSystemVersionString,
        "chip": String(cString: chip),
        "cores": ProcessInfo.processInfo.activeProcessorCount,
        "ram_gb": Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824,
        "thermal": ProcessInfo.processInfo.thermalState.rawValue,
        "git": gitCommit(),
        "log_file": Log.shared.url?.path ?? "none",
    ]
}

private func gitCommit() -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments = ["rev-parse", "--short", "HEAD"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    guard (try? p.run()) != nil else { return "unknown" }
    p.waitUntilExit()
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return out.isEmpty ? "uncommitted" : out
}
