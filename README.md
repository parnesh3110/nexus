# NEXUS

A Mac assistant you control with your hands and voice. Say "Jarvis", point at something on screen, pinch to grab it.

**Status: Phase 1, the spatial pointer.** Your webcam tracks your hand and a pointer follows it on screen, smoothed and calibrated. Every frame's latency and jitter can be recorded. There's no voice or AI yet. The first job is making the hand input feel solid, because everything else sits on top of it.

## Run it

Needs macOS 14+ and Xcode command line tools.

```bash
swift run -c release
```

The first time, macOS asks for camera access (for Terminal, if you launch it from there). A hand icon shows up in the menu bar. Hold your hand up about arm's length from the camera and a dot follows your index knuckle.

Menu bar options:
- **Calibrate:** sweep your hand to all four edges of your comfortable range for 4 seconds. That range then maps to the full screen.
- **Smoothing filter:** turn it off to see the raw, jittery signal.
- **Point with fingertip:** switch the anchor from knuckle to fingertip.
- **Record run to CSV:** writes one row per frame to `runs/`.

The dot shrinks and turns teal when you pinch. Grabbing things comes in Phase 2.

## How it works

```
camera (640x480, own queue, late frames dropped)
  -> Vision hand pose (21 landmarks, on-device)
  -> mirror + calibration box -> screen pixels
  -> One Euro filter (per axis)
  -> pinch detector (hysteresis + 2-frame hold)
  -> main thread: move a CALayer, nothing else
```

Decisions:
- **Everything except drawing runs off the main thread.** Later, voice and LLM calls can never freeze the pointer.
- **One Euro filter instead of a moving average.** A moving average adds the same lag at every speed. One Euro smooths hard when your hand is nearly still and backs off when it moves fast.
- **Knuckle as the default anchor.** Your fingertip moves when you pinch, so the pointer would slide right as you "click". The knuckle barely moves. The toggle is there so this can be measured, not assumed.
- **Pinch uses two thresholds.** It closes below 0.22 and opens above 0.32, as a ratio of hand size, so it doesn't flicker at the boundary. It's also scaled by hand size, so it works at any distance from the camera.
- **Losing the hand freezes and fades the pointer.** It never teleports and never stays "grabbed". After 0.3s the filter restarts, so the pointer doesn't glide from the old spot.

## Measuring it

The overlay shows live FPS, capture→pointer latency, Vision time, and jitter (raw → filtered, in px, meaningful while you hold still).

Phase 1 benchmark, to be run and committed to `runs/`:
1. Hold still for 10s: filter off vs. on, knuckle vs. fingertip. Compare jitter.
2. Pinch 20 times in place: how far the pointer moves during each pinch, knuckle vs. fingertip.
3. Sweep fast side to side: filter on vs. off. Compare lag.

Measured with `scripts/analyze_run.py` on the two runs in `runs/` (one person, one MacBook, indoor light):

| Metric | v1: absolute + fingertip | v2: trackpad + palm |
|--------|--------------------------|---------------------|
| Still-hand jitter (median RMS) | 12.9 px | 5.0 px |
| Pointer movement during a pinch (median) | 138 px | 7.9 px |
| Short tracking dropouts (1-5 frames) | 20 in 101 s | 3 in 147 s |
| Capture→pointer latency p50 / p95 | 113 / 151 ms | 82 / 118 ms* |

*The latency drop is probably lighting (shorter camera exposure), not the code change. Vision time was the same (~21 ms) in both.

## Logs

Every launch writes `logs/nexus-<timestamp>.log`, one JSON object per line. Menu bar → **Show log file in Finder** opens it.

- **Terminal** shows info and above. Run `NEXUS_LOG=debug swift run -c release` to also see debug events.
- **Console.app** shows the same lines under subsystem `dev.parnesh.nexus`.

What's logged:

| Category | Events |
|----------|--------|
| `app` | start (macOS, chip, RAM, screen, git commit), quit, fatal, uncaught_exception |
| `camera` | devices, permission_status/result, started (device, size, fps), runtime_error, interrupted |
| `hand` | acquired, lost, dropout_bridged (debug) |
| `gesture` | pinch_down (ratio, pos, aim_freeze_ms), pinch_up (held_ms, dragged_px, reason), aim_freeze_timeout (likely missed click) |
| `pointer` | lock_on/lock_off, box_placed, edge_push, reset (all debug) |
| `perf` | summary every 5s: fps, latency/vision p50/p95, hand %, frozen/locked/edge %, camera drops, CPU %, RAM; latency_high warning |
| `vision` | hand_pose_failed (rate limited) |
| `settings` | every menu change |
| `recorder` | started/stopped/start_failed |

Rule for later phases: log state transitions and failures, not per-frame values. Per-frame data goes to the CSV recorder.

## Roadmap

- [x] Phase 1: hand → calibrated, smoothed pointer + instrumentation
- [ ] Phase 2: pinch-drag real windows, swipe, open-palm cancel, gesture state machine
- [ ] Phase 3: "Jarvis" wake word, speech, interruptible replies
- [ ] Phase 4: "this / that / over there" resolved from where you're pointing
- [ ] Phase 5: temporal gesture model trained on my own recordings vs. the rule-based baseline
- [ ] Phase 6: on-demand screen understanding of the region you point at
- [ ] Phase 7: memory, polish, packaging
