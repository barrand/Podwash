# Slice 14 — Lock screen / Control Center / background audio

| Field | Value |
|-------|-------|
| **ID** | 14 |
| **Title** | Lock screen / Control Center / background audio |
| **Status** | Draft |
| **Crux** | Remote commands (play/pause/seek/skip) and Now Playing metadata are fully wired through protocol-wrapped system centers, and the audio session supports background playback — all asserted on injected doubles. |

## PRD / spec references

- PRD §2, §7 — Native media controls: lock screen, Control Center, Bluetooth/headset (hard requirement)

## Goal

PodWash behaves like a real podcast app when the screen is off.

## Deliverables

- Protocol wrapper over `MPRemoteCommandCenter` (extending the Slice 03 Now Playing wrapper); handlers for play/pause/seek/skip±
- `AVAudioSession` `.playback` category configuration on launch; `UIBackgroundModes` audio entitlement
- Elapsed time / duration / artwork in Now Playing info
- `RemoteCommandTests`, `BackgroundAudioTests`

## Depends on

- Slices 03, 08

**Parallelizable:** Yes — with Slices 12, 13.

## Out-of-scope

- CarPlay (Slice 15)
- Interruption/route-change edge polish beyond basic resume flag

## Acceptance criteria

- [ ] 1. Unit test: each remote command handler (play, pause, skip ±15 s, seek) invokes the corresponding `PlaybackEngine` call via the injected command-center double.
- [ ] 2. Unit test: audio session category is `.playback` with mode `.spokenAudio` after engine init (injected session double).
- [ ] 3. Unit test: Now Playing info double receives elapsed time updates on play/pause/seek, and duration matching the fixture (±0.25 s).
- [ ] 4. Structural: `UIBackgroundModes` contains `audio` in the built app's Info.plist (asserted in a unit test reading the bundle).
- [ ] 5. Full suite green via `scripts/verify.sh`.

## Verification mapping

| AC# | Test file | Test method | Notes |
|-----|-----------|-------------|-------|
| 1 | `PodWash/PodWashTests/RemoteCommandTests.swift` | `testHandlersInvokeEngine` | TBD |
| 2 | `PodWash/PodWashTests/BackgroundAudioTests.swift` | `testSessionCategoryPlayback` | TBD |
| 3 | `PodWash/PodWashTests/RemoteCommandTests.swift` | `testNowPlayingTimeUpdates` | TBD |
| 4 | `PodWash/PodWashTests/BackgroundAudioTests.swift` | `testBackgroundModeDeclared` | TBD |
| 5 | — | — | Command-level |

## Verification commands

```bash
scripts/verify.sh -only-testing:PodWashTests/RemoteCommandTests -only-testing:PodWashTests/BackgroundAudioTests
scripts/verify.sh    # Done gate
```

## Verification record (QA fills at Verify)

```
VERIFY RESULT: (pending)
```

## Done gate

- [ ] Every AC mapped to a test; all rows filled
- [ ] **Full suite green:** unfiltered `scripts/verify.sh` exit 0, failed 0, skipped 0
- [ ] Verification record pasted above
- [ ] Auto-commit on green: `slice-14: <short description>`

## Role artifacts

| Role | Gate | Artifact path |
|------|------|---------------|
| Architect | Light | wrapper protocol sketch inline |
| UX | Waived | — (system UI) |
