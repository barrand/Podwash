# PodWash Product Requirements (High-Level)

> Status: Living document. This captures the high-level product vision, features,
> and architecture recommendations for PodWash as a shippable app. It is
> intentionally not a detailed technical design; data models, API contracts, and
> UI mockups come after these requirements are confirmed. The agentic build
> harness ("dark factory") is a separate follow-up and is out of scope here.
>
> Legal notes in this document are engineering-informed research, not legal
> advice. Because the product is monetized, an IP attorney should review the
> cleaning and skip features before launch.

## 1. Vision and target audience

PodWash is a simplified podcast player that behaves like the podcast apps people
already know, plus two on-device features that make it uniquely family-friendly:

1. **Profanity handling** - for user-selected profanity, the user chooses to
   **skip** it or **mute** it (with an optional beep/quack overlay) at playback.
2. **Unrelated-content handling** - a user-controlled toggle for segments that seem
   superfluous to the story (tangents, filler, and other unrelated content, which
   can include ads); the user chooses to **skip** or **mute** those segments too.

**Both features are dynamic (no audio re-encoding).** PodWash analyzes the episode
once to produce a list of time ranges, then the player applies the chosen action
(skip or mute) live during playback. The original audio file is never modified,
copied, or re-hosted.

**Target audience:** a public but targeted, faith/family-friendly listenership.
Monetization is expected (subscription and/or one-time purchase).

**Design principle:** feel like a normal, polished podcast app first. These
features are opt-in enhancements layered on top of table-stakes podcast behavior -
never a degraded experience.

## 2. Core podcast features (table stakes)

These are the features common to essentially every podcast app; PodWash must do
them well before its differentiators matter.

- Subscribe to podcasts via public RSS feeds; search/add feeds.
- Podcast directory search (e.g. via a podcast index/search API) - can be phased.
- Episode list per show with show notes and artwork.
- Streaming playback and download for offline listening.
- Playback controls: play/pause, seek/scrubbing, skip forward/back, variable
  speed (e.g. 0.75x-3x), sleep timer.
- Resume/remember playback position per episode; mark played/unplayed.
- Queue / up-next and basic playlist behavior.
- **Native media controls** (see Section 7 - these are a hard requirement):
  lock screen, notification/Control Center, Bluetooth/headset buttons, CarPlay,
  and Android Auto.
- Auto-download and auto-delete-after-played settings.
- Subscriptions, positions, played state, and preferences are stored **on-device**
  (no account or backend required). See Section 9.

## 3. Differentiator 1 - Profanity handling (dynamic, no audio edit)

A per-subscription toggle to handle profanity across all episodes from a channel,
and/or the ability to enable it for individual episodes.

- **Per-channel toggle:** when on, new/played episodes from that subscription have
  profanity handling applied automatically.
- **Per-episode toggle:** enable profanity handling for a single episode on demand,
  independent of the channel toggle.
- **Skip or mute (user choice):** for matched profanity, the user chooses the
  action:
  - **Mute** - duck the audio to silence over the matched interval (optionally
    overlay a **beep** or **quack**), preserving episode timing. Recommended for
    single words.
  - **Skip** - seek past the matched interval (shortens the episode slightly). Best
    for longer spans; can sound choppy on single words, so mute is the default.
- **Clear UI indicators:** the UI must make it obvious which *channels* have
  profanity handling on and which *individual episodes* have it on (distinct
  badges/states for "channel on", "episode on", "analysis in progress", "off").
- **Mechanism (important):** this feature **does not edit or re-encode audio**.
  On-device, PodWash transcribes the episode once to get word-level timestamps,
  matches the user's word list, pads and merges intervals, and stores an
  **interval list**. At playback the native player applies the chosen action (mute
  or skip) live. The original download is never altered, and no modified copy is
  produced or stored.

### Playback action options and quality criteria

- **Mute/duck:** silence the interval (fast volume ramp in/out to avoid clicks);
  optional **beep**/**quack** overlay mixed in for the classic "censored" feel.
- **Skip:** auto-seek past the interval.
- Intervals are padded (short lead/tail) because ASR timing is imperfect - padding
  plus mute/skip prevents any leading/trailing leakage.
- Quality/acceptance criteria:
  - Every matched target word is fully covered (no leading/trailing leakage).
  - Non-target speech stays understandable.
  - No audible clicks at mute boundaries (short fade-in/out); no clipped
    neighboring words when skipping.
  - Playback behaves normally through native controls (scrub, speed, lock screen).

## 4. Differentiator 2 - Unrelated-content handling (dynamic, no audio edit)

A separate user toggle, **off by default**, framed as user-controlled handling of
content that seems superfluous to the story (which can include ads).

- **Skip or mute (user choice):** same two actions as profanity handling, applied
  to whole segments rather than single words:
  - **Skip** - auto-seek past the segment (default here, since these are usually
    long spans). Skips should be visible and easily overridable (e.g. a brief
    "skipped ~30s - tap to play" affordance).
  - **Mute** - silence the segment while keeping episode timing, for users who
    prefer not to jump.
- **Mechanism (important):** identical to profanity handling - **no audio edit**.
  On-device analysis produces a list of segment time ranges; the player applies the
  chosen action live during playback.
- **User control:** off by default; the user turns it on.
- **Framing:** presented as content curation ("skip/mute superfluous or tangential
  content"), not as an ad blocker.
- See Section 8 for the legal rationale (both actions are playback-time controls,
  the strongest posture).

## 5. Word and category selection

Users choose what gets cleaned.

- Selectable categories, for example: F-word, S-word, D-word, racial slurs, and
  God's name in vain, plus other common profanity groupings.
- User-configurable: enable/disable categories and add custom words.
- Sensible faith/family default profile, fully adjustable.
- Category/word lists are stored on-device (no account required).
- Matching normalizes casing/variants (e.g. base word plus common inflections),
  consistent with the prototype's normalization approach.

## 6. Architecture recommendation (dynamic playback, on-device)

**Recommendation: run both features on-device, and act at playback time - never
re-encode audio.** Both features share one pipeline:

> **Analyze once -> interval list -> native player applies the chosen action
> (skip or mute) live.**

Server-side is considered but discouraged (see costs and legal below).

### Analyze once (preprocess for timestamps, not for rendering)

- The only thing that must happen ahead of time is **detection**: transcribe the
  episode to get word-level timestamps (profanity) and segment it (unrelated
  content). This produces an interval list; it does **not** produce a modified
  audio file.
- **Why preprocess instead of true live transcription?** Whisper-family models are
  chunk/batch models, not instantaneous streamers - they need a few seconds of
  audio before they can transcribe that span. Transcribing live as the episode
  plays means a swear word is often already heard before it is detected. Avoiding
  that would require delaying playback behind a look-ahead buffer, which is fragile
  and risks leakage. Instead, transcribe the whole episode once (on download, or
  when a feature is toggled on) and cache the interval list. On modern phones
  WhisperKit / whisper.cpp run faster than real-time (a ~60-min episode in a few
  minutes), so this one-time step is cheap and enables instant, reliable, offline
  playback afterward.
- On-device speech-to-text with word-level timestamps is viable in 2026:
  - **iOS:** `SpeechAnalyzer` / `SpeechTranscriber` (iOS 26+, on-device,
    word-level timing via `attributeOptions: [.audioTimeRange]`), or **WhisperKit**
    (Core ML) for broader device/OS coverage and word timestamps.
  - **Android:** on-device ASR (e.g. `whisper.cpp` via JNI, or platform on-device
    recognizers on capable devices), with device fragmentation caveats.

### Act at playback (dynamic, no re-encoding)

- The native player consumes the interval list and applies the chosen action at the
  exact times, operating on the original file:
  - **iOS:** `AVMutableAudioMix` volume ramps on the `AVPlayerItem` for muting/
    ducking exact ranges; `AVAudioEngine` to mix in a beep/quack overlay; seek for
    skip. No re-encoding.
  - **Android:** ExoPlayer / Media3 custom `AudioProcessor` to attenuate or inject
    samples over exact ranges; seek for skip. No re-encoding.
- Word-level precision needs this native scheduling; JS position-polling is only
  precise enough for coarse (multi-second) skips, not tight word muting - another
  reason the differentiators live in the native module (see Section 7).
- Benefits: ~\$0 per-episode cost, privacy (audio never leaves the device), instant
  action switching (mute / skip / overlay without reprocessing), and the
  strongest legal posture (no derivative copy is ever created).

### On-device flow

1. User enables features (per channel / episode) and picks **skip** or **mute**.
2. App downloads the original episode audio.
3. **Analyze once** (on-device): ASR word timestamps + content segmentation, which
   feeds two matchers:
   - Match words against the selected profanity categories / word list.
   - Flag segments that seem superfluous to the story (may include ads).
4. Build one **interval list** (padded, merged) with an action per interval.
5. Cache the interval list (audio untouched, no re-encode).
6. Play via native controls (lock screen, Bluetooth, CarPlay, Android Auto).
7. Native player applies the action live: **mute/duck** (optional beep/quack
   overlay) or **seek-past**.

### Server-side (optional fallback only)

Kept only as a possible fallback for old/low-end devices that cannot run on-device
ASR acceptably. Note the fallback only needs to return an **interval list** (the
device still acts at playback); it does not require re-hosting modified audio.
Producing/serving modified audio server-side is specifically discouraged for legal
reasons (see Section 8) and should not be built without legal review.

## 7. Platform recommendation

**Recommendation: React Native + custom native modules (primary); full native
Swift + Kotlin (fallback).** Ship to iOS (App Store) and Android (Play Store) as a
serverless app (no backend required - see Section 9).

- **Standard media controls are not a trade-off in React Native.**
  `react-native-track-player` drives the real native media session on both
  platforms - lock screen, notification/Control Center, Bluetooth/headset buttons,
  CarPlay, and Android Auto - so background audio and native controls behave
  natively. This satisfies the "React Native only if no end-user UX trade-off"
  bar for the core player.
- **The differentiators require native code in any framework.** On-device ASR and
  precise playback-time audio control live in platform frameworks (iOS
  `SpeechAnalyzer`/WhisperKit for detection + `AVMutableAudioMix`/`AVAudioEngine`
  for muting/overlay; Android on-device ASR + ExoPlayer `AudioProcessor`). In React
  Native these become a Swift module and a Kotlin module bridged to JS. This is
  developer overhead, not a user-facing UX compromise.
- **Fallback to full native** (Swift + Kotlin) if maintaining the two native
  modules plus the bridge proves too costly, or if the on-device pipeline needs
  tighter platform integration/performance than the bridge allows.
- Either way, business logic that can be shared (feeds, subscriptions, local
  storage, preferences, word lists, skip/clean orchestration) should be centralized
  to avoid duplicated logic across platforms.

## 8. Legal and licensing considerations

Not legal advice; get an attorney to review before launch (monetized product).

### Both actions are playback-time controls (strong posture)

Because the dynamic model never re-encodes or stores a modified copy, both features
- for both profanity and unrelated content - are **playback controls**, not edits:

- **Skip** mirrors *Fox v. Dish (AutoHop), 9th Cir. 2013*, where automatic
  commercial-skipping was held not to infringe: the user initiates it, the
  publisher does not own the ads, and time/space-shifting is fair use. Skipping
  creates no copy.
- **Mute/duck** (with or without a beep/quack overlay) is likewise a real-time
  volume/output control over the user's own file, not the creation of a derivative
  copy. This is much closer to "skip" than to "edit," which strengthens the posture
  versus the earlier re-encode approach.
- **Note:** a live beep/quack overlay adds no copyrighted material of the
  publisher's and produces no stored modified file.

### Why on-device, not server-side

Server-side *rendering* would mean downloading episodes, producing modified copies,
and serving them back - i.e. reproduction and redistribution of modified
copyrighted audio. That is the pattern flagged as likely infringement in the
PodcastAdBlock case (which also re-hosted and resold ad-stripped copies). The
dynamic on-device model avoids that exposure entirely; even the optional server
fallback only returns an interval list, never modified audio.

### Residual risks and mitigations

- **Tortious interference / unfair competition** theories can target the developer
  (cf. *In re RetailMeNot Browser Extension Litigation*, SDNY 2026, which let a
  tortious-interference claim proceed). These generally favor ad-blockers but can
  still mean being sued.
- **App Store / Play Store policy** friction for anything framed as ad removal.
- **Mitigations:** on-device only; skip-not-rehost; skip feature off by default;
  frame the skip feature as content curation rather than ad blocking; do not
  redistribute or share modified audio between users/devices; attorney review
  before launch.

## 9. Data and services (serverless-first, no backend)

**PodWash needs no backend of its own.** A podcast app is inherently client-direct:
the device fetches RSS feeds and downloads episode audio straight from their public
URLs, and everything else (cleaning, skip, subscriptions, positions, word lists,
settings) lives on the device. There is no account and no cross-device sync -
deliberately, to keep the app simple and private.

### Everything runs on-device

- Subscriptions, playback positions, played state, per-channel and per-episode
  feature toggles, per-feature action choice (skip vs mute), word/category lists,
  and all preferences are stored in local storage.
- Cached interval lists (from the one-time analysis) are stored on-device.
- No login, no user accounts, no server to operate or pay for.

### External services (managed/keyless, not a backend we run)

- **Podcast search/discovery:** use Apple's iTunes Search API, which is free and
  keyless, called directly from the device. (Directory APIs that require a signed
  key, e.g. PodcastIndex, are avoided for now precisely because they would force a
  proxy.)
- **Purchases / monetization:** handled on-device via **StoreKit 2** (iOS) and
  **Play Billing** (Android), which provide cryptographically signed, on-device
  transaction verification - no server required. A managed option like RevenueCat
  can be added later if desired; still not our own server.
- **Crash reporting / analytics (optional):** a managed service such as Firebase
  Crashlytics/Analytics - a drop-in SDK, not infrastructure we run.
- **New-episode notifications:** use on-device background refresh (poll feeds
  locally) rather than server push, to stay serverless.

### Explicitly out (by choice)

- **Cross-platform account sync (iOS / Android):** intentionally not built - low
  value for the added complexity of accounts, auth, and a sync backend. Users get a
  clean single-device experience.
- **Server-side cleaning/detection:** not built for MVP. If ever revisited for
  very-low-end devices, it would return an **interval list only** (never modified
  audio) and is gated on legal review (Section 8).

If a genuine future need ever forces a backend (e.g. a paid discovery API that
requires key protection), the smallest possible addition is a thin serverless proxy
- not a stateful app backend.

## 10. Cost analysis (cleaning)

- **On-device (recommended): ~\$0 per episode** for transcription/analysis (uses
  the device's compute). Costs are device CPU/battery and first-run model
  download, not per-minute API fees.
- **Server-side (fallback, for reference):** transcription itself is cheap - the
  real costs are storage + egress of re-hosted files plus legal exposure.
  Approximate transcription rates (2026):

  | Option | Per audio hour |
  |---|---|
  | OpenAI `gpt-4o-mini-transcribe` | ~\$0.18 |
  | OpenAI `whisper-1` / `gpt-4o-transcribe` | ~\$0.36 |
  | Google Cloud STT (Dynamic Batch, ~24h turnaround) | ~\$0.24 |
  | Google Cloud STT (Standard) | ~\$0.96 |

  These are transcription-only and exclude storage, egress, compute, and
  operational overhead.

## 11. Open decisions

- Confirm React Native vs full native after a spike on the native cleaning module
  (validate on-device ASR quality/perf and the RN bridge).
- Minimum OS versions (iOS 26+ unlocks `SpeechAnalyzer`; older iOS needs WhisperKit
  or a fallback; define the Android device floor for on-device ASR).
- Default action per feature (mute vs skip) and which overlays to ship (beep/quack)
  for the mute action.
- When to run the one-time analysis (on download vs on first play vs on toggle) and
  the on-device retention policy for cached interval lists.
- Default word/category profile for the faith/family audience.
- Monetization model (subscription vs one-time vs freemium) via StoreKit 2 / Play
  Billing (optionally RevenueCat).
- Whether the skip feature ships at MVP or as a fast follow (pending attorney
  review).

## 12. Out of scope (for this document)

- The dark factory / agentic build harness (separate follow-up).
- Detailed technical design, data models, API contracts, and UI mockups.
- Actual implementation.

## Reference

- Prototype context: [`docs/archive/prototype-readme.md`](archive/prototype-readme.md)
- Prototype/spike plans: [`docs/magic-trick-plan.md`](magic-trick-plan.md),
  [`docs/phase-2a-plan.md`](phase-2a-plan.md),
  [`docs/phase-2b-plan.md`](phase-2b-plan.md),
  [`docs/pwa-playback-spike-plan.md`](pwa-playback-spike-plan.md)
