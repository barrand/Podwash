# PodWash

PodWash is a family-friendly podcast player for **iOS**. It behaves like the podcast
apps people already know, plus two on-device features:

- **Profanity handling** — for user-selected profanity, choose to **skip** it or
  **mute** it (with an optional beep/quack overlay).
- **Unrelated-content handling** — an optional, user-controlled toggle for segments
  that seem superfluous to the story (which can include ads); choose to **skip** or
  **mute** them.

Both features are **dynamic**: PodWash analyzes an episode once to build a list of
time ranges, then the player applies your chosen action (skip or mute) live during
playback. The original audio is never edited, re-encoded, copied, or re-hosted.
Everything runs **on the device** — private, negligible per-episode cost, and the
strongest legal posture.

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

Run the test suite the sanctioned way (dynamic simulator, result bundle, counts):

```bash
scripts/verify.sh                                      # full suite
scripts/verify.sh -only-testing:PodWashTests/FooTests  # fast filtered loop
```

CI runs the full suite on every push (`.github/workflows/test.yml`).

## Project status

Native iOS app in active slice-based development. Implementation follows **dark
factory** vertical slices ([`docs/slices/`](docs/slices/README.md)) — each slice is
done only when the full test suite is green via `scripts/verify.sh`, with an
automatic `slice-NN:` commit per completed slice.
