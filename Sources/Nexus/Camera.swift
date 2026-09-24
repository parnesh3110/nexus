import AVFoundation

enum NexusError: Error, CustomStringConvertible {
    case noCamera
    case cannotConfigure(String)

    var description: String {
        switch self {
        case .noCamera: return "No camera found."
        case .cannotConfigure(let what): return "Couldn't configure the camera: \(what)"
        }
    }
}

/// Delivers small (640x480) frames on a dedicated high-priority queue.
/// Everything downstream of the camera (Vision, filtering, gesture state) runs on this
/// queue, so the main thread only ever renders.
final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    let queue = DispatchQueue(label: "nexus.camera", qos: .userInteractive)
    var onFrame: ((CMSampleBuffer) -> Void)?
    var onDrop: (() -> Void)?

    private var observers: [NSObjectProtocol] = []

    /// Call on `queue` -- startRunning() blocks.
    func start() throws {
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified
        ).devices
        logInfo("camera", "devices", ["available": devices.map(\.localizedName)])

        session.beginConfiguration()
        // No preset on purpose: setting device.activeFormat below makes the session use
        // that format (the "input priority" preset is iOS-only and doesn't exist on macOS).

        // NEXUS_CAMERA=iPhone (any part of the name) picks that camera, e.g. an iPhone via
        // Continuity Camera, which can do 60fps when the built-in one can't.
        let wanted = ProcessInfo.processInfo.environment["NEXUS_CAMERA"]
        let chosen = wanted.flatMap { w in devices.first { $0.localizedName.localizedCaseInsensitiveContains(w) } }
        guard let device = chosen
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
            ?? AVCaptureDevice.default(for: .video)
        else { throw NexusError.noCamera }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw NexusError.cannotConfigure("input") }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true // never queue up stale frames -> no growing lag
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw NexusError.cannotConfigure("output") }
        session.addOutput(output)

        session.commitConfiguration()
        // Pick the format AFTER the session is configured: set earlier, adding the output made
        // the session switch back to 1920x1080 (log 20260924-001302), which slowed Vision down.
        try pickFastestFormat(device)
        observe()
        session.startRunning()

        // Some macOS versions reset the format on startRunning; put ours back if so
        if let f = chosenFormat, device.activeFormat != f {
            logWarn("camera", "format_reset_by_session", ["got": "\(CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription).width)"])
            try pickFastestFormat(device)
        }

        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        logInfo("camera", "started", [
            "device": device.localizedName,
            "model": device.modelID,
            "size": "\(dims.width)x\(dims.height)",
            "max_fps": device.activeFormat.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0,
            "frame_duration_ms": device.activeVideoMinFrameDuration.seconds * 1000,
            "running": session.isRunning,
        ])
    }

    private func observe() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { note in
            let err = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
            logError("camera", "runtime_error", ["error": err?.localizedDescription ?? "unknown", "code": err?.code ?? 0])
        })
        observers.append(nc.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { _ in
            logWarn("camera", "interrupted", ["note": "another app may be using the camera"])
        })
        observers.append(nc.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { _ in
            logInfo("camera", "interruption_ended")
        })
    }

    static let targetFps = 120.0
    private var chosenFormat: AVCaptureDevice.Format?

    /// Highest frame rate the camera offers (up to 120), and among those the smallest
    /// resolution >= 640x360. Vision only needs a small image; more frames matter more.
    private func pickFastestFormat(_ device: AVCaptureDevice) throws {
        let options = device.formats.compactMap { f -> (format: AVCaptureDevice.Format, w: Int32, h: Int32, fps: Double, range: AVFrameRateRange)? in
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            guard d.width >= 640, d.height >= 360,
                  let r = f.videoSupportedFrameRateRanges.max(by: { $0.maxFrameRate < $1.maxFrameRate })
            else { return nil }
            return (f, d.width, d.height, r.maxFrameRate, r)
        }
        let summary = Set(options.map { "\($0.w)x\($0.h)@\(Int($0.fps))" }).sorted()
        logInfo("camera", "formats", ["device": device.localizedName, "available": summary])

        guard let best = options.max(by: { a, b in
            // Round: 640x480 reports 29.97fps and 1080p 30.0, so an exact compare picked 1080p
            // (log 20260924-002140), which made Vision ~50% slower.
            let fa = min(a.fps, Self.targetFps).rounded(), fb = min(b.fps, Self.targetFps).rounded()
            if fa != fb { return fa < fb }
            return Int(a.w) * Int(a.h) > Int(b.w) * Int(b.h)
        }) else { return }
        chosenFormat = best.format

        let fps = min(best.fps, Self.targetFps)
        try device.lockForConfiguration()
        device.activeFormat = best.format
        // Use the range's own duration when we want its max rate: rebuilding it from a rounded
        // fps (29.97 -> 30) can fall outside the range, which throws and crashes.
        let duration = best.fps <= Self.targetFps
            ? best.range.minFrameDuration
            : CMTime(value: 1, timescale: CMTimeScale(Self.targetFps))
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
        device.unlockForConfiguration()

        if fps < 60 {
            logWarn("camera", "fps_capped", [
                "fps": fps,
                "note": "camera hardware limit; the pointer is still drawn at the display's refresh rate with prediction",
            ])
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        onFrame?(sampleBuffer)
    }

    /// Frames the camera threw away because we were still busy with the previous one.
    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        onDrop?()
    }
}
