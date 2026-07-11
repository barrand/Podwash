# Slice 16 — Beep/quack overlay (hard)

| Field | Value |
|-------|-------|
| **ID** | 16 |
| **Title** | Beep/quack overlay |
| **Status** | Ready |
| **Crux** | Overlay start/stop events during mute intervals align with cached interval boundaries within **±50 ms** on a pinned local fixture — without re-encoding the episode (ADR-000 §7 sync problem; Architect spike required before QA test spec). |

## PRD / spec references

- PRD §3 — Optional beep/quack overlay on mute
- `docs/adr/000-foundations.md` §7 — deferral rationale + prototype starting values (1 kHz, 0.35 volume, 5 ms fades)
- `docs/specs/matching-spec.md` §1 — non-normative overlay constants (`BEEP_FREQUENCY_HZ = 1000.0`, `BEEP_VOLUME = 0.35`, `BEEP_FADE_SECONDS = 0.005`)
- `docs/adr/006-playback-integration.md` — `PlaybackCoordinator` + cached intervals (overlay wires here, not re-analysis)

## Product decisions (user, 2026-07-10 — unblocks this slice)

| Decision | Choice |
|----------|--------|
| Default mute overlay | **off** — silent-first mute ships until the user opts in (ADR-000 §7) |
| Overlay modes | **off**, **beep**, **quack** — user-selectable in Settings (not present in Slice 13; added here) |
| Beep timbre | Synthetic **1000 Hz** sine at **0.35** peak, **5 ms** linear fades (matching-spec §1 starting values) |

## Goal

Ship the classic "censored" beep or quack during mute windows while preserving the no-re-encode, interval-driven playback architecture.

## Deliverables

- `MuteOverlayMode` enum — `.off`, `.beep`, `.quack` (`SettingsStore` persistence key `podwash.settings.muteOverlayMode`)
- `SettingsStore.muteOverlayMode` + `SettingsView` control — `accessibilityIdentifier("muteOverlayControl")`; `accessibilityValue` **`"off"`**, **`"beep"`**, or **`"quack"`** (extends Slice 13 settings; no new screen)
- `OverlayEngine` (or `MuteOverlayCoordinator`) — schedules overlay playback from mute interval boundaries via injectable `OverlayEventRecording` protocol (production: `AVAudioEngine` player node or secondary player synced to `PlaybackEngine` timeline per overlay ADR)
- `PlaybackCoordinator` wiring — reads `SettingsStore.muteOverlayMode`; applies overlay only when `CensorAction == .mute` and mode ≠ `.off`
- Bundled overlay assets — `beep.wav` (pinned synthetic 1 kHz tone per product decision) and `quack.wav` (distinct bundled asset; tests assert by **asset ID**, not timbre)
- `PodWash/PodWashTests/OverlaySyncTests.swift` + `OverlayEventRecorder` test double
- Offline verification helper — composite render or mix-bus tap that reuses Slice 04 `OfflineRenderRMS` windowing (interior/exterior thresholds)
- Architect spike + ADR — `docs/adr/0XX-overlay-sync.md` with measured sync jitter on simulator; supersedes ADR-000 §7 deferral

## Fixture strategy (pinned)

| Asset | Path / value | Role |
|-------|----------------|------|
| Episode audio | `PodWash/PodWashTests/Fixtures/audio/sine-300hz-5s.wav` | Reuse Slice 04 sine fixture (local file, offline render) |
| Mute intervals | `[(1.0, 1.5), (3.0, 3.4)]` | Pinned schedule — **2** intervals, **0.9 s** total mute span |
| Beep asset | `PodWash/PodWashTests/Fixtures/audio/beep-1khz.wav` (or app bundle `beep.wav`) | 1000 Hz, peak **0.35**, **5 ms** fades; provenance doc |
| Quack asset | `PodWash/PodWashTests/Fixtures/audio/quack.wav` (or app bundle) | Distinct asset ID `"quack"`; timbre not gated |
| Overlay recorder | `OverlayEventRecorder` test double | Records `overlayStart(at:assetID:)` / `overlayStop(at:)` in **player timeline seconds** |
| Exterior windows | Same as Slice 04 AC2 | 10 ms windows fully outside all intervals by **≥0.050 s** |

## Depends on

- Slice 08 — `PlaybackCoordinator`, cached intervals → `PlaybackEngine`
- Slice 13 — `SettingsStore` / `SettingsView` extension point (overlay setting **not** shipped in Slice 13)
- Slice 23 — MVP Library/player shell first (overlay control lives in production Settings chrome)

**Parallelizable:** Yes — with Slices 15, 18–21 once Slice 23 is **Done**.

## Out-of-scope

- Quack asset sourcing polish (any licensed or synthetic bundled asset OK; no perceptual timbre gate)
- Perceptual "sounds right" or ear-test review (post-MVP automation target)
- Overlay during **skip** action (mute-only)
- Re-running analysis or changing interval math when overlay mode toggles
- Streamed/remote assets (ADR-000 §3 — local files only)
- CarPlay- or lock-screen-specific overlay controls (in-app Settings only)
- StoreKit gating of overlay modes (Slice 17 deferred)
- Physical device sync calibration as a Done gate (simulator-runnable tests only)

## Acceptance criteria

Automatable only. **XCTSkip is not allowed on core ACs** — a mapped test that cannot run must fail.

- [ ] 1. Unit test (`OverlayEventRecorder` + pinned intervals `[(1.0, 1.5), (3.0, 3.4)]` on `sine-300hz-5s.wav`, `muteOverlayMode == .beep`): exactly **2** `overlayStart` events; each start timestamp is within **±0.050 s** of the matching interval `start` (paired 1:1 with intervals in order).
- [ ] 2. Unit test (same fixture/mode): exactly **2** `overlayStop` events; each stop timestamp is within **±0.050 s** of the matching interval `end`; recorder reports **0** overlay-active samples in every 10 ms window fully outside all intervals by **≥0.050 s** (exterior definition matches Slice 04 AC2).
- [ ] 3. Offline-render test (same fixture/intervals): with `muteOverlayMode == .beep`, every 10 ms window fully inside `[start + 0.030, end − 0.030]` for each interval has RMS **>0.10** full scale; with `muteOverlayMode == .off`, the same interior windows have RMS **<0.01** full scale (Slice 04 mute baseline).
- [ ] 4. Unit test (`SettingsStore` + recorder): fresh isolated `UserDefaults` → `muteOverlayMode == .off`; drive playback with `.beep` → **2** starts with `assetID == "beep"`; reload store, set `.quack` → **2** starts with `assetID == "quack"`; set `.off` → **0** overlay start events across the full fixture duration.
- [ ] 5. Unit test (seek resync): interval `[1.0, 1.5]` only, mode `.beep`; play until player time **≥1.20 s** (inside interval), then `seek(to: 2.5)`; within **0.200 s** of seek completion, recorder `activeOverlayCount == 0` and **0** additional overlay events until the next scheduled interval (none on this fixture).
- [ ] 6. Full suite green via `scripts/verify.sh` (**exit 0, failed 0, skipped 0**).

## Verification mapping

| AC# | Test file | Test method | Notes |
|-----|-----------|-------------|-------|
| 1 | `PodWash/PodWashTests/OverlaySyncTests.swift` | `testOverlayStartSync` | 2 starts; ±0.050 s vs interval `start`; pinned schedule |
| 2 | `PodWash/PodWashTests/OverlaySyncTests.swift` | `testOverlayEndAndExteriorSilence` | 2 stops; ±0.050 s vs `end`; 0 active time in exterior windows |
| 3 | `PodWash/PodWashTests/OverlaySyncTests.swift` | `testOfflineRenderOverlayEnergy` | Interior RMS >0.10 (beep) vs <0.01 (off); reuse `OfflineRenderRMS` windows |
| 4 | `PodWash/PodWashTests/OverlaySyncTests.swift` | `testOverlaySettingRespected` | off/beep/quack asset IDs; default `.off`; 0/2 event counts |
| 5 | `PodWash/PodWashTests/OverlaySyncTests.swift` | `testSeekResync` | seek 1.2→2.5; active count 0 within 0.200 s; no orphan events |
| 6 | — | — | Command-level: unfiltered `scripts/verify.sh` exit 0, failed 0, skipped 0 |

## Verification commands

```bash
# Fast inner loop (NOT sufficient for Done):
scripts/verify.sh -only-testing:PodWashTests/OverlaySyncTests

# Done gate — FULL suite, zero failures, zero skips:
scripts/verify.sh
```

## Verification record (QA fills at Verify)

```
VERIFY RESULT: (pending)
```

## Plan review record (coordinator fills before downstream roles)

```
ADR review: (pending)
Test spec review: (pending)
```

## Done gate

- [ ] Every AC mapped to a test; all rows filled
- [ ] **Full suite green:** unfiltered `scripts/verify.sh` exit 0, failed 0, skipped 0
- [ ] Verification record pasted above (exit code + counts + `.xcresult` path)
- [ ] Auto-commit on green: `slice-16: beep/quack overlay`

## Role artifacts

| Role | Gate | Artifact path |
|------|------|---------------|
| PM | Required | `docs/slices/slice-16-beep-overlay.md` (this file) |
| Architect | Required (spike + ADR) | `docs/adr/0XX-overlay-sync.md` — measured sync validation; supersedes ADR-000 §7 |
| UX | Required | `docs/slices/slice-16-ux.md` — `muteOverlayControl` states/values (extends Settings) |
| QA | Required | `PodWash/PodWashTests/OverlaySyncTests.swift`, overlay fixtures + provenance |
| Engineer | Required | `OverlayEngine`, `SettingsStore`/`SettingsView` overlay mode, `PlaybackCoordinator` wiring |
