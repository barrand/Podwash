# PodWash

PodWash is a native iOS podcast player that gives listeners more control over what
they hear. It combines a familiar library, queue, downloads, and full playback
controls with optional tools for skipping or muting unwanted moments.

## What it does

- **Plays podcasts your way.** Subscribe to shows, browse episodes, build a queue,
  download episodes for offline listening, adjust speed, set a sleep timer, and
  resume where you left off.
- **Cleans selected words.** Choose profanity categories or add custom words, then
  have matching moments muted or skipped during playback. A beep or quack overlay
  is also available for muted moments.
- **Skips likely ad breaks.** Optional cloud ad detection examines timed transcript
  text, never podcast audio, to identify likely ad segments. Listeners can turn it
  off at any time.
- **Shows what is ahead.** The player displays preparation and cleaned segments on
  its seek bar, and a synchronized transcript can follow playback.

PodWash applies skip and mute actions live while an episode plays. It never edits,
re-encodes, copies, or re-hosts the original podcast audio.

## Privacy and analysis

Word detection and playback controls run on the device. Cloud ad detection is
optional and uses timed transcript text only after the listener enables it; audio
is not uploaded. Preferences, subscriptions, downloads, and listening progress are
stored on the device.

## Platform

- **iOS only** (App Store) — native Swift/SwiftUI.
- Prior Python prototype and PWA spike work has been retired; this is a greenfield
  native iOS build.

## Documentation

**Product requirements (source of truth):**
[`docs/product-requirements.md`](docs/product-requirements.md)

**Multitask workflow (dark factory — vertical slices gated by automated tests):**
[`docs/multitask-workflow.md`](docs/multitask-workflow.md)

**Matching algorithm spec (normative, with hand-computed goldens):**
[`docs/specs/matching-spec.md`](docs/specs/matching-spec.md)

**Foundational technical decisions:**
[`docs/adr/000-foundations.md`](docs/adr/000-foundations.md)

## Getting started

1. Open `PodWash/PodWash.xcodeproj`.
2. Select the shared `PodWash` scheme and an iOS Simulator target.
3. Build and run (⌘R).

Run verification through the sanctioned runner. Each invocation prints live phase
updates and writes logs, an `.xcresult`, and a Markdown report under
`build/test-results/` (the current result is `build/test-results/latest.md`).

```bash
scripts/verify.sh -only-testing:PodWashTests/FooTests  # focused local loop
VERIFY_TIER=3a scripts/verify.sh                       # complete unit suite
VERIFY_TIER=3b scripts/verify.sh                       # complete UI suite
scripts/release-verify.sh                              # release test gate
```

Set `VERIFY_VISIBLE_UI=1` for an opt-in Simulator foreground during focused UI
diagnosis. Push CI runs build + unit tests; the complete unit/UI gate runs nightly,
on manual dispatch, and immediately before a release.

## Project status

Native iOS app in active slice-based development. Implementation follows **dark
factory** vertical slices ([`docs/slices/`](docs/slices/README.md)) — each slice is
done only when the full test suite is green via `scripts/verify.sh`, with an
automatic `slice-NN:` commit per completed slice.
