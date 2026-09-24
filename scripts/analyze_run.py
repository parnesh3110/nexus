"""Summarize a recorded run: tracking dropouts, still-hand jitter, pinch drift, latency.

    python3 scripts/analyze_run.py runs/run-XXXX.csv [more.csv ...]

Needs pandas + numpy (pip install pandas numpy).
"""
import sys

import numpy as np
import pandas as pd

STILL_PX = 30  # a 0.5s window counts as "holding still" if raw spread is under this
WINDOW = 15    # frames (~0.5s at 30fps)


def rms(x, y):
    return float(np.sqrt(((x - x.mean()) ** 2 + (y - y.mean()) ** 2).mean()))


def runs_of(values):
    out, cur, n = [], values[0], 0
    for v in values:
        if v == cur:
            n += 1
        else:
            out.append((cur, n))
            cur, n = v, 1
    out.append((cur, n))
    return out


def analyze(path):
    d = pd.read_csv(path)
    if "mode" not in d:
        d["mode"] = "absolute"
    d["config"] = d["mode"] + "/" + d["anchor"] + "/" + np.where(d["filter"] == 1, "filter", "raw")
    print(f"\n=== {path}")
    print(f"duration {d.t.iloc[-1] - d.t.iloc[0]:.0f}s, {len(d)} frames, "
          f"{1 / d.t.diff().median():.0f} fps")
    print(f"latency p50 {d.latency_ms.median():.0f} ms, p95 {d.latency_ms.quantile(.95):.0f} ms | "
          f"vision p50 {d.vision_ms.median():.1f} ms")

    dropouts = [n for v, n in runs_of(d.hand.values) if v == 0 and n <= 5]
    print(f"short dropouts (1-5 frames): {len(dropouts)}  <- these used to cause stutter")

    h = d[d.hand == 1]
    if len(h) > 1:
        W, H = h.x.max(), h.y.max()
        pinned = ((h.x <= 0.5) | (h.x >= W - 0.5) | (h.y <= 0.5) | (h.y >= H - 0.5)).mean()
        frozen = (np.hypot(h.x.diff(), h.y.diff()).dropna() < 0.01).mean()
        print(f"pointer stuck on a screen edge: {pinned:.0%} of frames | not moving: {frozen:.0%}")

    d["seg"] = (d.hand != d.hand.shift()).cumsum()
    rows = []
    for _, g in d[d.hand == 1].groupby("seg"):
        for i in range(0, len(g) - WINDOW, 3):
            w = g.iloc[i:i + WINDOW]
            r = rms(w.raw_x, w.raw_y)
            if r < STILL_PX and w.config.nunique() == 1:
                rows.append((w.config.iloc[0], r, rms(w.x, w.y)))
    if rows:
        j = pd.DataFrame(rows, columns=["config", "raw_px", "shown_px"])
        print("\nstill-hand jitter (median RMS px, lower = steadier):")
        print(j.groupby("config").agg(windows=("raw_px", "size"),
                                      raw_px=("raw_px", "median"),
                                      shown_px=("shown_px", "median")).round(1).to_string())

    onsets = d.index[(d.pinched.diff() == 1)]
    drift = []
    for i in onsets:
        w = d.loc[max(i - 4, 0):i + 4]
        if (w.hand == 1).all():
            drift.append((w.config.iloc[0], float(np.hypot(w.x.iloc[-1] - w.x.iloc[0], w.y.iloc[-1] - w.y.iloc[0]))))
    if drift:
        p = pd.DataFrame(drift, columns=["config", "px"])
        print("\npointer movement during a pinch (median px, lower = clicks land where you aimed):")
        print(p.groupby("config").px.agg(["size", "median"]).round(1).to_string())


if __name__ == "__main__":
    for f in sys.argv[1:]:
        analyze(f)
