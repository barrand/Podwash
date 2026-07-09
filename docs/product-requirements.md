# PodWash Product Requirements (High-Level)

> **Source of truth:** This PRD is the canonical **WHAT/WHY** — product vision,
> constraints, legal, monetization, and non-goals. It changes rarely. **HOW/WHEN**
> for delivery lives in [`docs/slices/`](slices/README.md) (one file per slice:
> crux, acceptance criteria, verification, status). See
> [Source of truth model](slices/README.md#source-of-truth-model) for how PRD and
> slices work together and what goes where.
>
> Status: Living document. This captures the high-level product vision, features,
> and architecture for PodWash as a shippable **native iOS** app. It is intentionally
> not a detailed technical design; data models, API contracts, and UI mockups come
> after these requirements are confirmed. Build process and verification strategy
> ("dark factory" — automated tests gate every slice) live in
> [`multitask-workflow.md`](multitask-workflow.md).
>
> **Platform decision (2026):** iOS only. Prior Python prototype and PWA spike work
> is retired. This is a greenfield Swift/SwiftUI build.
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
  lock screen, Control Center, Bluetooth/headset buttons, and CarPlay.
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
- **Normative algorithm spec:** the exact matching, normalization, padding, and
  merge rules (with constants and hand-computed golden examples) are pinned in
  [`specs/matching-spec.md`](specs/matching-spec.md) — the Swift implementation
  ports from that document.

### Playback action options and quality criteria

- **Mute/duck:** silence the interval (fast volume ramp in/out to avoid clicks);
  optional **beep**/**quack** overlay mixed in for the classic "censored" feel.
- **Skip:** auto-seek past the interval.
- Intervals are padded (short lead/tail) because ASR timing is imperfect - padding
  plus mute/skip prevents any leading/trailing leakage.
- Quality/acceptance criteria (verified by automated tests per
  [`multitask-workflow.md`](multitask-workflow.md), not manual ear tests):
  - Every matched target word is fully covered (no leading/trailing leakage) —
    assert via interval boundary tests on synthetic fixtures.
  - Non-target speech stays understandable — golden interval fixtures; perceptual
    checks deferred to post-MVP automation.
  - No audible clicks at mute boundaries (short fade-in/out); no clipped
    neighboring words when skipping — programmatic energy/discontinuity tests at
    boundaries.
  - Playback behaves normally through native controls (scrub, speed, lock screen) —
    UI and unit tests on `PlaybackEngine` and remote commands.

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
- Matching normalizes casing/variants (e.g. base word plus common inflections).
- Normalization and matching semantics (exact set membership over enumerated
  inflections; no substring or fuzzy matching) are defined normatively in
  [`specs/matching-spec.md`](specs/matching-spec.md), including seeded category
  starting lists.

## 6. Architecture (dynamic playback, on-device, iOS)

**Run both features on-device, and act at playback time - never re-encode audio.**
Both features share one pipeline:

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
  when a feature is toggled on) and cache the interval list. On modern iPhones
  WhisperKit / whisper.cpp run faster than real-time (a ~60-min episode in a few
  minutes), so this one-time step is cheap and enables instant, reliable, offline
  playback afterward.
- On-device speech-to-text with word-level timestamps is viable in 2026:
  - **Primary (TBD spike):** `SpeechAnalyzer` / `SpeechTranscriber` (iOS 26+,
    on-device, word-level timing via `attributeOptions: [.audioTimeRange]`).
  - **Fallback / broader coverage:** **WhisperKit** (Core ML) for older iOS
    versions and word timestamps on a wider device range.

### Act at playback (dynamic, no re-encoding)

- `AVPlayer` / `AVPlayerItem` with `AVMutableAudioMix` volume ramps for muting/
  ducking exact ranges; `AVAudioEngine` to mix in a beep/quack overlay; seek for
  skip. No re-encoding.
- Word-level precision needs native scheduling tied to the media timeline; coarse
  position-polling is only precise enough for multi-second skips, not tight word
  muting.
- Benefits: negligible per-episode cost, privacy (audio never leaves the device),
  instant action switching (mute / skip / overlay without reprocessing), and the
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
6. Play via native controls (lock screen, Bluetooth, CarPlay).
7. Native player applies the action live: **mute/duck** (optional beep/quack
   overlay) or **seek-past**.

### Server-side (optional fallback only)

Kept only as a possible fallback for old/low-end devices that cannot run on-device
ASR acceptably. Note the fallback only needs to return an **interval list** (the
device still acts at playback); it does not require re-hosting modified audio.
Producing/serving modified audio server-side is specifically discouraged for legal
reasons (see Section 8) and should not be built without legal review.

## 7. Platform and tech stack (iOS native)

**Decision: native iOS only — Swift + SwiftUI.**

| Layer | Technology |
|-------|------------|
| UI | SwiftUI |
| Playback | AVFoundation (`AVPlayer`, `AVPlayerItem`, `AVMutableAudioMix`) |
| Background / lock screen / CarPlay | `MPNowPlayingInfoCenter`, `MPRemoteCommandCenter`; CarPlay framework when ready |
| On-device ASR | **TBD spike:** `SpeechAnalyzer` (iOS 26+) vs WhisperKit (Core ML) |
| Local storage | SwiftData or Core Data (TBD) |
| RSS / feeds | `URLSession` + XML parsing (TBD library) |
| Purchases | StoreKit 2 |
| Crash reporting (optional) | Firebase Crashlytics or similar managed SDK |

Prior prototype work (Python CLI, preprocessing lab, PWA playback spike) validated
the core *concept* (word-level timestamps + interval-based action) but is **not**
carried forward as code. Matching logic and interval padding will be reimplemented
in Swift from this spec.

## 8. Legal and licensing considerations

Not legal advice; get an attorney to review before launch (monetized product).

### Both actions are playback-time controls (strong posture)

Because the dynamic model never re-encodes or stores a modified copy, both features
(for both profanity and unrelated content) are **playback controls**, not edits:

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
- **App Store policy** friction for anything framed as ad removal.
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
- **Purchases / monetization:** handled on-device via **StoreKit 2**, which
  provides cryptographically signed, on-device transaction verification - no server
  required. A managed option like RevenueCat can be added later if desired; still
  not our own server.
- **Crash reporting / analytics (optional):** a managed service such as Firebase
  Crashlytics/Analytics - a drop-in SDK, not infrastructure we run.
- **New-episode notifications:** use on-device background refresh (poll feeds
  locally) rather than server push, to stay serverless.

### Explicitly out (by choice)

- **Android / cross-platform:** not in scope for initial release.
- **Cross-device account sync:** intentionally not built - low value for the added
  complexity of accounts, auth, and a sync backend. Users get a clean
  single-device experience.
- **Server-side cleaning/detection:** not built for MVP. If ever revisited for
  very-low-end devices, it would return an **interval list only** (never modified
  audio) and is gated on legal review (Section 8).

If a genuine future need ever forces a backend (e.g. a paid discovery API that
requires key protection), the smallest possible addition is a thin serverless proxy,
not a stateful app backend.

## 10. Cost analysis (cleaning)

**On-device (recommended):** negligible per-episode cost for transcription/analysis
(uses the device's compute). Costs are device CPU/battery and first-run model
download, not per-minute API fees.

**Server-side (fallback, for reference):** transcription itself is cheap - the real
costs are storage plus egress of re-hosted files plus legal exposure. Approximate
transcription rates (2026, per audio hour):

- OpenAI gpt-4o-mini-transcribe: about 0.18 USD
- OpenAI whisper-1 / gpt-4o-transcribe: about 0.36 USD
- Google Cloud STT Dynamic Batch (~24h turnaround): about 0.24 USD
- Google Cloud STT Standard: about 0.96 USD

These are transcription-only and exclude storage, egress, compute, and operational
overhead.

## 11. Open decisions and constraints

**Constraint (decided, ADR-000):** `AVMutableAudioMix` volume ramps are unreliable
on streamed/HLS assets, so **muting is only guaranteed on downloaded local files**.
The product flow for cleaned listening is **download-before-clean-listen**: an
episode with cleaning enabled is downloaded (or fully cached) before cleaned
playback starts. Streaming remains available for uncleaned playback. See
[`adr/000-foundations.md`](adr/000-foundations.md) §3.

**Differentiator 2 placement:** unrelated-content handling (§4) remains core to
the vision but is scheduled as a **post-MVP track** (slices 18–19: segmentation
spike, then integration) — it depends on the full analyze/playback pipeline, its
own detection R&D, and the attorney question below. It is planned with concrete
slice files, not deferred into vagueness.

Open decisions (agents must **halt and ask** rather than assume — see the
coordinator decision protocol in [`multitask-workflow.md`](multitask-workflow.md)):

- **On-device ASR choice:** `SpeechAnalyzer` (iOS 26+) vs WhisperKit — spike
  required (slice 05); drives minimum iOS version. Current floor: iOS 26.1
  (the created Xcode project); raising for ASR is tolerated, lowering is a
  product decision.
- **Local persistence:** SwiftData vs Core Data for subscriptions, positions, and
  cached interval lists (surfaces at slice 11).
- **Default action per feature** (mute vs skip) and which overlays to ship (beep/quack)
  for the mute action.
- **When to run the one-time analysis** (on download vs on first play vs on toggle)
  and the on-device retention policy for cached interval lists.
- **Default word/category profile** for the faith/family audience.
- **Monetization model** (subscription vs one-time vs freemium) via StoreKit 2
  (optionally RevenueCat) — hard halt-and-ask gate at slice 17.
- **Whether the skip feature ships at MVP** or as a fast follow (pending attorney
  review).
- **CarPlay timing:** ship with MVP or fast follow after core playback is solid
  (surfaces at slice 15).

Decided-and-deferred (not open, just late): beep/quack overlay sync mechanism is
its own hard slice (16) per ADR-000 §7.

## 12. Out of scope (for this document)

- Slice-level verification commands and CI workflow (see
  [`multitask-workflow.md`](multitask-workflow.md)).
- Detailed technical design, data models, API contracts, and UI mockups.
- Actual implementation.
- Android and React Native cross-platform paths (explicitly retired).

## Reference

- Multitask build workflow: [docs/multitask-workflow.md](multitask-workflow.md)
