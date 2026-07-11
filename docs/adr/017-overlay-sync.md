# ADR-017 — Overlay sync: beep/quack during mute intervals

| Field | Value |
|-------|-------|
| **Status** | Accepted |
| **Date** | 2026-07-11 |
| **Supersedes** | [ADR-000](000-foundations.md) §7 **deferral only** (mute remains silent-first by default; sync is no longer deferred) |
| **Builds on** | [ADR-000](000-foundations.md) §1–§3 (AVPlayer + audioMix, offline verification, local files); [ADR-001](001-playback-engine.md) (`PlaybackEngine` seek / `avPlayer`); [ADR-002](002-interval-scheduler.md) (mute mix + `OfflineRenderRMS` settle margin `M = 0.030`); [ADR-006](006-playback-integration.md) (`PlaybackCoordinator` + cached intervals); [ADR-010](010-settings-word-lists.md) (`SettingsStore` / `SettingsView` extension) |
| **Slice** | [slice-16-beep-overlay.md](../slices/slice-16-beep-overlay.md) |

## Context

Slice 16 ships PRD §3 optional beep/quack during **mute** windows without
re-encoding the episode. ADR-000 §7 deferred this as a hard AVPlayer-timeline sync
problem. Product pins (2026-07-10):

| Decision | Choice |
|----------|--------|
| Default | **off** (silent mute until the user opts in) |
| Modes | `off`, `beep`, `quack` |
| Beep timbre | Synthetic **1000 Hz** sine, peak **0.35**, **5 ms** linear fades |

Acceptance requires overlay start/stop aligned to cached mute interval bounds within
**±50 ms** on the pinned Slice 04 fixture, plus offline RMS energy when beep is on.
Architect must prove the sync path empirically before QA writes the test spec.

## Empirical validation (simulator spike)

Throwaway: `PodWash/PodWashTests/_OverlaySyncSpike.swift` (not a Done-gate test).

**Method:**

1. `AVPlayer` + `addBoundaryTimeObserver` on mute bounds
   `[(1.0, 1.5), (3.0, 3.4)]` against `sine-300hz-5s.wav`.
2. Record `player.currentTime().seconds` at each fire; pair chronologically to
   commanded bounds.
3. Probe `AVAudioPlayer.prepareToPlay()` → `play()` start latency on a temp 1 kHz
   WAV (peak 0.35, 5 ms fades).

**Measured (iPhone 17 simulator, 2026-07-11):**

| Metric | Value |
|--------|-------|
| Max \|observed − commanded\| (boundary only) | **0.0002 s** |
| `AVAudioPlayer` start latency | **0.0266 s** |
| Combined (boundary + start) | **0.0268 s** |
| Slice AC tolerance | 0.050 s |
| Passes ±50 ms | **YES** |

Raw log excerpt:

```text
=== SPIKE RESULT overlay-sync ===
device: simulator
fixture: sine-300hz-5s.wav
commanded_bounds_sorted: [1.0, 1.5, 3.0, 3.4]
max_abs_boundary_error_s: 0.0002
avaudioplayer_start_latency_s: 0.0266
combined_budget_s (boundary+start): 0.0268
ac_tolerance_s: 0.050
passes_50ms: YES
=== END SPIKE RESULT ===
```

**Implication:** Boundary observers alone are ~0.2 ms accurate. The dominant error is
overlay **start latency** (~27 ms). Combined stays under ±50 ms with ~23 ms headroom
on simulator. A full `AVAudioEngine` graph is **not** required for the AC budget.

## Decision

### 1. Sync + playback mechanism

| Concern | Choice |
|---------|--------|
| Timeline sync | `AVPlayer.addBoundaryTimeObserver` on mute interval **starts** and **ends** (same API family as skip observers in ADR-002 / `PlaybackEngine`) |
| Overlay audio | Pre-prepared **`AVAudioPlayer`** instances for bundled assets (not a live `AVAudioEngine` mix graph for MVP) |
| Episode mute | Unchanged: `AVMutableAudioMix` via `IntervalScheduler` (ADR-002) — overlay is **additive**, never baked into the mix |
| Re-encode | **Forbidden** — no `AVMutableComposition` rewrite of the episode file |

**Why not AVAudioEngine for MVP:** ADR-000 §7 named it as one option. Spike shows a
second `AVAudioPlayer` + boundary observers meet ±50 ms. Engine graphs add session /
node complexity without improving the AC that QA can assert via event recording.

**Event timebase:** All overlay events are recorded in **player timeline seconds**
(`AVPlayer.currentTime().seconds` at the moment the engine decides start/stop), not
wall-clock.

### 2. Module layout / file boundaries

| File | Target | Status | Responsibility |
|------|--------|--------|----------------|
| `PodWash/PodWash/MuteOverlayMode.swift` | app | **new** | `enum MuteOverlayMode: String` — `.off`, `.beep`, `.quack` |
| `PodWash/PodWash/OverlayEventRecording.swift` | app | **new** | Injectable protocol for start/stop (production no-op or telemetry; tests use recorder) |
| `PodWash/PodWash/OverlayEngine.swift` | app | **new** | Arms/disarms boundary observers; plays/stops bundled overlay; seek resync |
| `PodWash/PodWash/SettingsStore.swift` | app | **changed (additive)** | `muteOverlayMode` + key `podwash.settings.muteOverlayMode` |
| `PodWash/PodWash/SettingsView.swift` | app | **changed (additive)** | Control `muteOverlayControl`; values `"off"` / `"beep"` / `"quack"` |
| `PodWash/PodWash/PlaybackCoordinator.swift` | app | **changed (additive)** | Holds `OverlayEngine`; applies overlay schedule when action is mute and mode ≠ `.off` |
| `PodWash/PodWash/PlaybackEngine.swift` | app | **changed (minimal)** | Optional seek-completion hook for overlay resync only — **do not** fold overlay into skip-observer logic |
| App bundle | app | **new** | `beep.wav`, `quack.wav` (asset IDs `"beep"` / `"quack"`) |
| `PodWash/PodWashTests/OverlaySyncTests.swift` | test | **new (QA)** | AC1–AC5 |
| `PodWash/PodWashTests/OverlayEventRecorder.swift` | test | **new (QA)** | Test double for `OverlayEventRecording` |
| `PodWash/PodWashTests/OverlayOfflineComposite.swift` (or extend `OfflineRenderRMS`) | test | **new (QA)** | Mute render + software mix of beep PCM into mute interiors |
| Fixtures | test | **new (QA)** | `beep-1khz.wav` (+ provenance), `quack.wav` (+ provenance); reuse `sine-300hz-5s.wav` |

No changes to `IntervalScheduler`, `IntervalBuilder`, `TimedWord`, analysis pipeline, or
interval math when overlay mode toggles.

### 3. Key types / public API sketch

```swift
enum MuteOverlayMode: String, Codable, Equatable, Sendable {
    case off
    case beep
    case quack
}

/// Player-timeline overlay events (seconds on the AVPlayer clock).
protocol OverlayEventRecording: AnyObject {
    func overlayStart(at time: TimeInterval, assetID: String)
    func overlayStop(at time: TimeInterval)
}

@MainActor
final class OverlayEngine {
    init(
        player: AVPlayer,
        eventRecorder: (any OverlayEventRecording)? = nil,
        assetBundle: Bundle = .main
    )

    /// Arm start/stop observers for mute intervals only. Clears prior arms.
    /// `mode == .off` or empty `muteIntervals` → no observers, stop any active overlay.
    func apply(
        muteIntervals: [(start: TimeInterval, end: TimeInterval)],
        mode: MuteOverlayMode
    )

    /// After seek completes: stop active overlay; ensure no orphan play until the
    /// next scheduled start (AC5). Re-evaluate if `currentTime` is inside a mute
    /// window (start overlay immediately if so; else idle).
    func handleSeekCompleted(currentTime: TimeInterval)

    /// Tear down observers + stop playback (schedule clear / deinit).
    func reset()
}
```

**Asset IDs (stable for tests):**

| Mode | Asset ID | Bundle resource |
|------|----------|-----------------|
| `.beep` | `"beep"` | `beep.wav` |
| `.quack` | `"quack"` | `quack.wav` |

Quack timbre is **not** gated — only asset ID and event counts/timing.

**`SettingsStore` (additive, ADR-010 pattern):**

- Key: `podwash.settings.muteOverlayMode`
- Fresh / missing key → `.off`
- Persist raw string `"off"` / `"beep"` / `"quack"`
- Isolated `UserDefaults` suites in unit tests (same as Slice 13)

**`PlaybackCoordinator` wiring:**

1. After `applyCurrentSchedule()` (or in parallel with it), derive mute intervals from
   the **scheduled** list where `action == .mute`.
2. Read `settingsStore.muteOverlayMode` (injected or passed at apply time).
3. Call `overlayEngine.apply(muteIntervals:mode:)`.
4. When `currentAction` (or per-interval action) is `.skip`, overlay stays off for
   those intervals — **mute-only** (slice out-of-scope for skip).
5. Mode / action changes re-apply overlay without calling `analyze`.

**Seek (AC5):**

- Prefer routing through `PlaybackEngine.seek(to:completion:)` so
  `OverlayEngine.handleSeekCompleted` runs within the completion path.
- Within **0.200 s** of seek completion: `activeOverlayCount == 0` when landing
  outside all mute intervals; no further overlay events until the next scheduled
  start.

### 4. Overlay scheduling algorithm

Given mute intervals `I` (sorted by start) and mode `M`:

1. If `M == .off` or `I` empty → `reset()`; return.
2. `prepareToPlay()` the asset for `M` once (reuse player instance across intervals).
3. Register boundary times = all `start` ∪ all `end` values (timescale 600, matching skip).
4. On fire at time `t` (sample `player.currentTime().seconds`):
   - If `t` matches a **start** (within a small match epsilon, e.g. 0.05 s) and no
     overlay active for that interval → `play()` + `overlayStart(at:assetID:)`.
   - If `t` matches an **end** → `stop()` + `overlayStop(at:)`.
5. Loop / restart the overlay asset if a mute span exceeds asset duration (beep should
   be long enough for the longest expected mute, or loop while active — Engineer
   choice; tests use ≤0.5 s mutes on the fixture).

**Rate note:** MVP ACs pin rate 1.0. Boundary observers track the item timeline, so
they remain correct if rate changes later; do not block this slice on rate×overlay
matrix testing.

### 5. Offline verification (AC3) — composite, not live mix-bus

Realtime `AVAudioPlayer` output is **not** assertable via ADR-000 §2
`AVAssetReaderAudioMixOutput` (overlay is outside the episode `audioMix`).

**QA contract:**

1. Render muted episode with existing `OfflineRenderRMS` + mute schedule
   (interior settle `M = 0.030` per ADR-002).
2. When mode is `.beep`, **software-mix** pinned `beep-1khz.wav` (or synthetic
   equivalent at peak 0.35) into samples covering each mute `[start, end]`.
3. Windowed RMS on interiors `[start + 0.030, end − 0.030]`:
   - `.beep` → RMS **> 0.10** full scale
   - `.off` → RMS **< 0.01** full scale (mute baseline unchanged)

This proves the **energy contract** for the overlay asset in mute windows. Sync
timing (AC1/AC2/AC5) is proven via `OverlayEventRecorder`, not offline PCM phase.

### 6. Fixture strategy (pinned)

| Asset | Path / value | Role |
|-------|----------------|------|
| Episode | `Fixtures/audio/sine-300hz-5s.wav` | Slice 04 sine |
| Mute intervals | `[(1.0, 1.5), (3.0, 3.4)]` | 2 intervals, 0.9 s mute span |
| Beep | App `beep.wav` + test `beep-1khz.wav` | 1000 Hz, peak 0.35, 5 ms fades; provenance doc |
| Quack | App `quack.wav` + test copy | Distinct ID `"quack"` only |
| Exterior windows | Slice 04 AC2 / ADR-002 | Fully outside all intervals by ≥ `0.050` s |

### 7. Cross-cutting impact

| Surface | Impact |
|---------|--------|
| `PlaybackEngine` | Minimal: seek-completion notification for overlay; **do not** merge overlay into skip observer |
| `PlaybackCoordinator` | Additive overlay apply; settings read |
| `SettingsStore` / `SettingsView` | Additive mode + control (UX: `docs/slices/slice-16-ux.md`) |
| `IntervalScheduler` / analysis / `TimedWord` | **None** |
| Parallel slices 15 / 18–21 | Safe if they avoid the same Settings / coordinator lines; serialize on those files if conflicting |

### 8. Out of scope (unchanged from slice)

- Overlay during skip; StoreKit gating; CarPlay/lock-screen overlay controls;
  streamed assets; physical-device calibration as Done gate; perceptual ear tests.

## Consequences

- ADR-000 §7 deferral is lifted: overlay ships as boundary-observer + `AVAudioPlayer`,
  default **off**.
- QA asserts sync with `OverlayEventRecorder` (±50 ms) and energy with offline
  composite RMS — not live audio session taps.
- Engineer must keep mute mix and overlay on separate paths; mode toggles never
  re-run analysis.
- Spike file `_OverlaySyncSpike.swift` may be deleted after this ADR is accepted;
  it is not part of the Done suite.
