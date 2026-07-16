# Task 027 — Sleep timer visible duration labels

| Field | Value |
|-------|-------|
| **ID** | 027 |
| **Title** | Sleep timer visible duration labels |
| **Status** | Queued |
| **Kind** | tweak |
| **Priority** | P2 |
| **Area** | `PodWash/PodWash/PlaybackControlsView.swift`, `PodWash/PodWashUITests/PlaybackControlsUITests.swift` |
| **Crux** | Each sleep-timer tap shows a human-readable duration (or Off) on the control so armed state is obvious without VoiceOver. |

## Outcome

**Current:** `sleepTimerButton` cycles presets (`off → 900 → 1800 → 3600 → off`) and pauses playback once on deadline, but the only visual change is `moon.zzz` ↔ `moon.zzz.fill`. Sighted users get no readable feedback; duration exists only as `accessibilityValue` (`"off"` / `"900"` / `"1800"` / `"3600"`). Speed already shows discrete text (`"1.0×"`).

**Desired:** Match the speed-button pattern with static preset labels on the control: **`Off` → `15m` → `30m` → `60m` → `Off`**. Keep moon icon optional. Do not change the a11y value contract or pause-on-deadline behavior. No live remaining countdown.

## Acceptance criteria

- [ ] 1. UI test (`-UITestFixtureAudio`): at launch, `sleepTimerButton` `accessibilityValue == "off"` and the control’s visible label text equals `"Off"`.
- [ ] 2. UI test: three consecutive taps from off assert `accessibilityValue` **`"900"` → `"1800"` → `"3600"`** and visible label text **`"15m"` → `"30m"` → `"60m"`** in the same order.
- [ ] 3. UI test: a fourth tap from `"3600"` / `"60m"` returns `accessibilityValue == "off"` and visible label text `"Off"`.
- [ ] 4. Existing unit contract unchanged: `SleepTimer` preset cycle and pause-on-deadline behavior remain as Slice 12 (`PodWashTests/SleepTimerTests` still green); no change to `accessibilityValue` string encoding (`"off"` / `"900"` / `"1800"` / `"3600"`).

## Surgical test scope

| AC# | Test id | New? |
|-----|---------|------|
| 1–3 | `PodWashUITests/PlaybackControlsUITests/testSleepTimerButtonCyclesPresets` | no (extend) |
| 4 | `PodWashTests/SleepTimerTests/testTimerFireExtendCancel` | no (must stay green; no edit) |

## Authorized test changes

- `PodWashUITests/PlaybackControlsUITests/testSleepTimerButtonCyclesPresets` — may extend assertions to require visible label strings `"Off"` / `"15m"` / `"30m"` / `"60m"` alongside existing `accessibilityValue` checks; may add the fourth-tap off cycle assert if missing.

## Depends on

- None

## Out of scope

- Live remaining-time countdown on the button
- New sleep-timer presets or durations beyond Slice 12 `[900, 1800, 3600]`
- CarPlay / remote-command sleep timer
- Changing VoiceOver `accessibilityValue` encoding from seconds strings
- Speed-button UI changes

## Human checklist

(not applicable)

## Verification record

> Loop writes `VERIFY RESULT:` here. For tasks, `tier=2` and `filtered=1` are valid for Done.

```
VERIFY RESULT: (pending)
```
