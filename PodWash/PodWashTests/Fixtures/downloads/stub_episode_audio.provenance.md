# stub_episode_audio.bin

Synthetic 1024-byte episode-audio stub for Slice 10 download tests (ADR-008 §8).
Not real M4A/AAC media — a deterministic byte payload for sandbox write,
progress-callback, and cancel/resume assertions.

## Generation (independent of PodWash code)

Hand-specified pattern; produced with Python 3 (stdlib only):

```python
data = bytes(i % 256 for i in range(1024))
```

| Property | Value |
|----------|-------|
| Size | **1024 bytes** exactly |
| Pattern | `byte[i] = i mod 256` for `i ∈ [0, 1023]` |
| First 16 bytes (hex) | `00 01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f` |
| Last 16 bytes (hex) | `f0 f1 f2 f3 f4 f5 f6 f7 f8 f9 fa fb fc fd fe ff` |
| SHA-256 | `785b0751fc2c53dc14a4ce3d800e69ef9ce1009eb327ccf458afe09c242c26c9` |

## Why this pattern

- **Non-circular:** Generated from a closed-form index rule, not from
  `DownloadManager`, `StubDownloadURLProtocol`, or any PodWash implementation.
- **Deterministic:** Same bytes on every platform; AC1 asserts on-disk count == 1024
  and chunk boundaries (256 B × 4) align with the normative stub contract.
- **Verifiable:** Any tool can recompute `bytes(i % 256 for i in range(1024))` and
  compare SHA-256 without reading app code.

## Copies

| Path | Target | Purpose |
|------|--------|---------|
| `PodWash/PodWashTests/Fixtures/downloads/stub_episode_audio.bin` | PodWashTests | Unit tests + `StubDownloadURLProtocol` body |
| `PodWash/PodWash/Fixtures/downloads/stub_episode_audio.bin` | PodWash app | `-UITestFixtureDownload` instant copy (Engineer) |

Both copies must be **byte-identical** to this provenance record.

## Chunk schedule (ADR-008 §8)

Default stub delivery: **4 equal HTTP body chunks** of 256 bytes each, async with
50 ms inter-chunk gap. Chunk *k* (0-based) carries bytes `[256k, 256k + 255]`.
