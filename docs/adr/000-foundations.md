# ADR-000 — Foundations: playback, verification, transcript schema, iOS floor

| Field | Value |
|-------|-------|
| **Status** | Accepted |
| **Date** | 2026-07-08 |
| **Scope** | Cross-slice decisions every implementation slice builds on |

## Context

PodWash is a dark-factory build: every slice is gated by automated tests, so the
core audio architecture must be chosen for **deterministic verifiability**, not
just runtime behavior. These decisions were previously scattered across the PRD,
workflow doc, and slice drafts; this ADR pins them.

## Decisions

### 1. Playback + mute: AVPlayer + AVMutableAudioMix

Playback uses `AVPlayer`/`AVPlayerItem`. Interval muting uses
`AVMutableAudioMix` volume ramps (`setVolumeRamp(fromStartVolume:toEndVolume:timeRange:)`)
attached to the player item. Skip uses seek-past. **No MTAudioProcessingTap** —
taps are realtime, hard to assert on, and unnecessary for mute/skip.

### 2. Verification of muting: offline render, not realtime tapping

Tests must not listen to a live simulator audio session. Instead:

- Build the **same `AVMutableAudioMix`** the player would use.
- Render the asset offline with `AVAssetReader` + `AVAssetReaderAudioMixOutput`,
  passing that audioMix.
- Assert **RMS/energy on the rendered PCM buffers** inside vs outside intervals,
  with numeric thresholds (e.g. muted-window RMS < 0.01 full scale; unmuted
  windows within 3 dB of fixture reference).

This makes audio assertions deterministic and CI-safe: same mix object → same
math → same PCM, no realtime scheduling flake.

### 3. Streaming caveat: muting requires local files

`AVMutableAudioMix` volume ramps are **unreliable on streamed/HLS assets**
(mix is frequently ignored for non-file-based assets). Consequence:

- Profanity/segment muting is only guaranteed on **downloaded local files**.
- The product flow is **download-before-clean-listen**: an episode with cleaning
  enabled is downloaded (or fully cached) before cleaned playback starts.
- Recorded as a PRD §11 constraint; UX must not offer "clean this stream live."

### 4. Shared transcript schema

All slices exchange transcripts as Codable JSON, seconds as `Double`:

```json
[ { "word": "String", "start": 0.0, "end": 0.0 } ]
```

Swift type: `struct TimedWord: Codable, Equatable { let word: String; let start: Double; let end: Double }`.
ASR (Slice 05) **produces** it; the matcher (Slice 02) **consumes** it; fixtures
encode it. Schema changes require a superseding ADR.

### 5. iOS floor policy

Build at the deployment target of the user-created Xcode project: **iOS 26.1**.
The ASR spike (Slice 05) may confirm or adjust this floor (e.g. `SpeechAnalyzer`
availability). Tolerance: raising the floor for ASR is **acceptable**; lowering it
(to widen device support via WhisperKit) is a product decision to surface to the
user, not an agent call.

### 6. Test destination: scripts/verify.sh only

No hardcoded simulator names anywhere in docs, rules, or slice files.
`scripts/verify.sh` resolves an available iPhone simulator dynamically, writes an
`.xcresult` bundle, prints executed/failed/skipped counts, and is the **only**
sanctioned way to run verification.

**Amended 2026-07-15 — Forge verification / Done semantics.** Full unfiltered
suite wall-time was blocking Forge UX when every task and slice had to wait on
tier-3 before exit. Verification is now two gates:

1. **Per-item exit gate (Implemented).** A green **tier-2** surgical run
   (`VERIFY_TIER=2`, filtered slice/task tests via `-only-testing:` /
   `VERIFY_SLICE_TESTS`) is enough to mark the item **Implemented**. This
   applies to **both** Forge tasks and slices. Filtered runs remain the fast
   inner loop; they are not the ship gate.

2. **Ship gate (Done).** **Done** requires an unfiltered full suite:
   `VERIFY_TIER=3` with `filtered=0`, run from Forge Floor **Full verify & ship**
   (or `forge_loop` `ship_now`). On green, all **Implemented** items are
   promoted to **Done** and receive that run's `VERIFY RESULT:` line as the
   recorded ship evidence.

3. **Split ship diagnostics.** `VERIFY_TIER=3a` (PodWashTests only) and
   `VERIFY_TIER=3b` (PodWashUITests only) exist for faster ship-gate
   diagnostics. Ship-green still requires a full **tier-3** run, **or**
   sequential **3a + 3b** both green and recorded together as the ship gate.

4. **Push policy.** Push may happen per-item once the item is **Implemented**
   (green-on-surgical, verified-on-batch). CI remains a safety net for
   regressions between surgical exit and the next ship-gate promotion.

iOS floor (§5) and offline-render audio assertions (§2) are unchanged.

### 7. Beep/quack overlay: deferred, flagged hard

Mixing an overlay sound during mute windows requires `AVAudioEngine` (or a second
player) synchronized to the `AVPlayer` timeline — a genuinely hard sync problem
that AVMutableAudioMix cannot do alone. **Deferred to its own late slice**
(see Slice 16); mute ships silent-first. Prototype starting values
(1 kHz, 0.35 volume, 5 ms fades) are recorded in
[`docs/specs/matching-spec.md`](../specs/matching-spec.md) §1.

## Consequences

- Slices 03/04 (player shell, interval mute) target local-file playback and
  offline-render verification from day one; no realtime audio assertions ever.
- Download management (Slice 10) is a hard prerequisite for cleaned playback of
  real episodes; until then, cleaning works on bundled/downloaded fixtures.
- Any slice touching `TimedWord`, `PlaybackEngine`'s public API, or the audioMix
  strategy must reference this ADR and supersede it if it deviates.
