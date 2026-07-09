# sine-300hz-5s.wav

Generated locally with:

```bash
ffmpeg -f lavfi -i "aevalsrc=0.9*sin(2*PI*300*t):s=44100:d=5" \
       -ac 1 -c:a pcm_s16le sine-300hz-5s.wav
```

5 s, 300 Hz constant-amplitude sine, amplitude 0.9, mono, 44.1 kHz, 16-bit
lossless PCM WAV (~431 KB, < 1 MB). See ADR-002 §8.

## Why `aevalsrc`, not `sine` (Revision 2026-07-08)

The earlier command used ffmpeg's `sine` lavfi source with `volume=0.9`. That is
**wrong**: ffmpeg's `sine` source is **not full scale** — it emits a peak of
≈ 0.125 (−18 dB), so `volume=0.9` produced a ≈ 0.11-peak (−19 dB) fixture and the
RMS thresholds (> 0.25 exterior, RMS reference 0.636) became unreachable.

`aevalsrc` evaluates the expression directly at full scale, so
`0.9*sin(2*PI*300*t)` yields an actual peak of ≈ 0.90. Verified:

```
ffmpeg -i sine-300hz-5s.wav -af volumedetect -f null -
  max_volume:  -0.9 dB   → peak ≈ 0.90
  mean_volume: -3.9 dB   → RMS  ≈ 0.636  (= 0.9/√2)
size: 441078 bytes (~431 KB, < 1 MB)
codec: pcm_s16le  sample_rate: 44100  channels: 1  duration: 5.000000
```

## Provenance is independent of PodWash code

This is a pure analytic sine produced by ffmpeg's `aevalsrc` (an external tool
evaluating a closed-form expression). It is **not** generated from
`IntervalScheduler` output (or any PodWash code), so using it as the golden input
for the offline-render RMS / boundary tests is non-circular per the QA
golden-provenance rule. Expected silent / full windows are derived from the
interval list and the fades-outside ramp placement in ADR-002 §4 (plus the
settle-margin classification in §7) — again, not from the code under test.

## Why these exact parameters (ADR-002 §8)

| Property | Value | Rationale |
|----------|-------|-----------|
| Waveform | constant-amplitude sine | uniform reference energy for windowed RMS |
| Frequency | **300 Hz** | inherent max adjacent-sample slew `≈ 0.9·2π·300/44100 = 0.0385` full scale, safely `< 0.05` — so AC3's raw-sample discontinuity bound is meaningful (any excess is a mix-induced click, not carrier slew). A 440 Hz sine already slews `≈ 0.063 > 0.05` before any muting. |
| Amplitude | **0.9** full scale (measured peak ≈ 0.90 / −0.9 dB) | full-window RMS `≈ 0.9/√2 ≈ 0.636 ≫ 0.25` (AC2 exterior bound, measured 0.6364); exterior windows (≥ settle margin from a boundary) render at full volume. |
| Duration | 5 s | covers the AC2 intervals `[(1.0,1.5),(3.0,3.4)]` plus fade bands with margin |
| Channels / rate | mono / 44.1 kHz | one RMS series; a 10 ms window is exactly 441 samples |
| Container / codec | lossless PCM WAV (`pcm_s16le`) | no lossy codec ringing / energy smearing at interval boundaries |

## Note on render smoothing (why the harness uses a settle margin)

`AVAssetReaderAudioMixOutput` smooths commanded volume ramps over a ~20 ms floor,
so a fade placed just outside an interval bleeds ~20 ms into the interval
interior. The fixture is unaffected (it is an analytic sine); the harness handles
this at classification time via a 30 ms settle margin (`M`, ADR-002 §4/§7). This
provenance note is purely about the fixture and is independent of that behavior.
