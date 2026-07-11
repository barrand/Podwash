# beep-1khz.wav (and `beep.wav` copy)

Synthetic overlay asset for Slice 16 AC3 offline composite and AC4 asset-ID tests.

## Generation (independent of PodWash code)

```bash
ffmpeg -f lavfi -i "aevalsrc=0.35*sin(2*PI*1000*t):s=44100:d=0.5" \
  -af "afade=t=in:st=0:d=0.005,afade=t=out:st=0.495:d=0.005" \
  -ac 1 -c:a pcm_s16le beep-1khz.wav
```

| Property | Value | Source |
|----------|-------|--------|
| Waveform | 1000 Hz sine | Product decision / matching-spec §1 `BEEP_FREQUENCY_HZ` |
| Peak | **0.35** full scale (measured max ≈ −9.1 dB) | matching-spec §1 `BEEP_VOLUME` |
| Fades | **5 ms** linear in/out | matching-spec §1 `BEEP_FADE_SECONDS` |
| Duration | 0.5 s | Covers longest pinned mute span (0.5 s) on fixture |
| Rate / channels | 44.1 kHz mono PCM16 | Matches `sine-300hz-5s.wav` harness |

Verified:

```
ffmpeg -i beep-1khz.wav -af volumedetect -f null -
  max_volume: -9.1 dB  → peak ≈ 0.35
```

Interior RMS of a full-scale 0.35 sine ≈ **0.247** (> AC3 threshold 0.10). Provenance is
**external ffmpeg** evaluating a closed-form expression — not generated from `OverlayEngine`
or `OverlayOfflineComposite`.

`beep.wav` in this directory is a byte-identical copy for bundle resource name `"beep"` per ADR-017.
