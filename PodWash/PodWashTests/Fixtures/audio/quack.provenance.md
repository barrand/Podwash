# quack.wav

Distinct bundled overlay asset for Slice 16 AC4 (`assetID == "quack"`). Timbre is **not**
gated — only asset identity and event counts matter.

## Generation (independent of PodWash code)

```bash
ffmpeg -f lavfi -i "aevalsrc=0.35*sin(2*PI*440*t)*exp(-8*t):s=44100:d=0.15" \
  -af "afade=t=in:st=0:d=0.005" \
  -ac 1 -c:a pcm_s16le quack.wav
```

| Property | Value |
|----------|-------|
| Waveform | 440 Hz decaying sine burst (distinct from 1 kHz beep) |
| Peak | 0.35 at onset |
| Duration | 0.15 s |
| Rate / channels | 44.1 kHz mono PCM16 |

Provenance: **external ffmpeg** — not derived from PodWash overlay implementation.
