import CoreGraphics
import Vision

/// Landmarks in Vision's normalized image space (0...1, origin bottom-left, NOT mirrored).
struct HandSample {
    let indexTip: CGPoint
    let thumbTip: CGPoint
    let wrist: CGPoint
    let indexMCP: CGPoint
    let middleMCP: CGPoint
    let ringMCP: CGPoint
    let littleMCP: CGPoint

    /// Min confidence of the four knuckles. Gates whether we trust the pointer.
    let pointerConfidence: Float
    /// Min confidence of thumb tip + index tip. Gates whether we trust the pinch.
    /// The wrist is NOT required: in run-20260923-235455 your wrist was out of frame
    /// 18% of the time, and every one of those frames was a click that couldn't register.
    let pinchConfidence: Float
    let wristConfidence: Float

    /// Center of the four knuckles. Averaging 4 points cuts landmark noise,
    /// and knuckles barely move when you pinch.
    var palm: CGPoint {
        CGPoint(
            x: (indexMCP.x + middleMCP.x + ringMCP.x + littleMCP.x) / 4,
            y: (indexMCP.y + middleMCP.y + ringMCP.y + littleMCP.y) / 4
        )
    }

    var fingerGap: Double { distance(thumbTip, indexTip) }
    var palmLength: Double { distance(wrist, middleMCP) }
    var knuckleSpan: Double { distance(indexMCP, littleMCP) }
}

func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
    hypot(a.x - b.x, a.y - b.y)
}

final class HandTracker {
    private let request: VNDetectHumanHandPoseRequest = {
        let r = VNDetectHumanHandPoseRequest()
        r.maximumHandCount = 1
        return r
    }()

    private var failures = 0
    // Built for video: reuses state between frames instead of setting up a new handler each time
    private let sequence = VNSequenceRequestHandler()

    func detect(_ pixelBuffer: CVPixelBuffer) -> HandSample? {
        do {
            try sequence.perform([request], on: pixelBuffer, orientation: .up)
        } catch {
            failures += 1
            if failures <= 3 || failures % 100 == 0 { // don't flood the log at 30fps
                logWarn("vision", "hand_pose_failed", ["error": "\(error)", "count": failures])
            }
            return nil
        }

        guard let observation = request.results?.first,
              let p = try? observation.recognizedPoints(.all),
              let indexTip = p[.indexTip], let thumbTip = p[.thumbTip], let wrist = p[.wrist],
              let indexMCP = p[.indexMCP], let middleMCP = p[.middleMCP],
              let ringMCP = p[.ringMCP], let littleMCP = p[.littleMCP]
        else { return nil }

        return HandSample(
            indexTip: indexTip.location,
            thumbTip: thumbTip.location,
            wrist: wrist.location,
            indexMCP: indexMCP.location,
            middleMCP: middleMCP.location,
            ringMCP: ringMCP.location,
            littleMCP: littleMCP.location,
            pointerConfidence: min(indexMCP.confidence, middleMCP.confidence, ringMCP.confidence, littleMCP.confidence),
            pinchConfidence: min(indexTip.confidence, thumbTip.confidence),
            wristConfidence: wrist.confidence
        )
    }
}
