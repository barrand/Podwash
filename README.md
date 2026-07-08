# PodWash

PodWash is a simplified, family-friendly podcast player for iOS and Android. It
behaves like the podcast apps people already know, plus two on-device features:

- **Profanity handling** - for user-selected profanity, choose to **skip** it or
  **mute** it (with an optional beep/quack overlay).
- **Unrelated-content handling** - an optional, user-controlled toggle for segments
  that seem superfluous to the story (which can include ads); choose to **skip** or
  **mute** them.

Both features are **dynamic**: PodWash analyzes an episode once to build a list of
time ranges, then the player applies your chosen action (skip or mute) live during
playback. The original audio is never edited, re-encoded, copied, or re-hosted.
Everything runs **on the device** - private, ~\$0 per episode, and the strongest
legal posture.

## Platforms and architecture (at a glance)

- **Apps:** iOS (App Store) + Android (Play Store).
- **Framework (recommended):** React Native with `react-native-track-player` for
  fully native media controls (lock screen, Bluetooth, CarPlay, Android Auto),
  plus custom native modules (Swift/Kotlin) for on-device transcription and audio
  processing. Full native (Swift + Kotlin) is the fallback.
- **On-device analysis + dynamic playback:** iOS `SpeechAnalyzer` / WhisperKit and
  Android on-device ASR provide word-level timestamps once per episode; the native
  player then mutes (`AVMutableAudioMix` / ExoPlayer `AudioProcessor`) or skips at
  playback - no re-encoding.
- **No backend (serverless):** the device fetches RSS feeds and downloads audio
  directly; subscriptions, positions, word lists, and settings live on-device.
  Discovery uses Apple's keyless search API; purchases use on-device StoreKit 2 /
  Play Billing. No accounts and no cross-device sync (by choice).

## Documentation

- **Product requirements (start here):**
  [`docs/product-requirements.md`](docs/product-requirements.md)
- **Prototype notes (archived):**
  [`docs/archive/prototype-readme.md`](docs/archive/prototype-readme.md)
- **Prototype / spike plans:** [`docs/magic-trick-plan.md`](docs/magic-trick-plan.md),
  [`docs/phase-2a-plan.md`](docs/phase-2a-plan.md),
  [`docs/phase-2b-plan.md`](docs/phase-2b-plan.md),
  [`docs/pwa-playback-spike-plan.md`](docs/pwa-playback-spike-plan.md)

## Project status

PodWash began as a command-line "magic trick" prototype that proved the core
detection mechanic: find target words with word-level timestamps. That timestamp
detection now underpins the on-device profanity and unrelated-content features
(which act at playback rather than editing audio). The current focus is defining
the product; see the requirements doc above. The Python prototype and
preprocessing lab remain available - see the archived notes for how to run them.
