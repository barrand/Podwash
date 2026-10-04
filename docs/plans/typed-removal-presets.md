# Typed removal presets — Jev migration plan

**Status:** approved direction; V7 evaluation in progress
**Scope:** replace the single cloud "ad span" meaning with typed removable spans,
three listener-facing skip presets, a corrected golden policy, and a Jev-backed
server candidate. Previews and recaps are always preserved.

## Product decisions

PodWash should classify what an interruption *is*, then apply the listener's
chosen preset locally. A listener changing a preset must not require another
cloud request or another Jev classification.

Three presets are the complete first-release UI:

| Preset | Removes |
| --- | --- |
| **Skip obvious interruptions** | Paid ads and sponsor messages, including host reads, DAI creatives, underwriting, and attached legal copy or CTAs. |
| **Skip more interruptions** | Skip obvious interruptions plus other-show promos, publisher/show promotions, and membership or support appeals. |
| **Skip most interruptions** | Skip more interruptions plus engagement requests, production credits, network IDs, and routine sign-offs. |

The default is **Skip obvious interruptions**. It removes clear paid ads while
minimizing the chance of removing wanted show material. **Skip more
interruptions** and **Skip most interruptions** are explicitly marked
**Experimental** until fresh-holdout evaluation validates their safety.

The following are editorial invariants and must never be returned as removable
spans in any preset:

- previews and recaps;
- substantive reporting, discussion, interviews, and storytelling;
- a quoted, archival, or historical commercial used as the subject of the
  episode's discussion;
- a complete or substantial cross-post/feed-drop episode;
- a mixed sentence that cannot safely be split at a deterministic boundary.

"Off topic" is supporting evidence, not a removal rule. It cannot alone make a
tangent, credit, archival clip, or guest discussion removable.

## Internal taxonomy

The server retains the richer categories below. They are deliberately more
specific than the first-release settings so future UI changes do not require
reanalyzing old episodes.

| Category | Meaning | Preset mapping |
| --- | --- | --- |
| `paid_ad` | Current commercial, sponsor read, DAI creative, its disclaimer, or CTA. | All |
| `underwriting` | Sponsor/funder acknowledgement that functions as paid support. | All |
| `cross_show_promo` | Trailer or explicit invitation to consume another show. | Skip more, Skip most |
| `publisher_promo` | Publisher/show book, merch, event, newsletter, or related property. | Skip more, Skip most |
| `membership_appeal` | Paid subscription, donation, Patreon, or ad-free feed appeal. | Skip more, Skip most |
| `engagement_request` | Follow, rate, review, contact, or free-subscription request. | Skip most |
| `production_credit` | Crew, producer, editor, music, or staff credit. | Skip most |
| `network_id` | Bare publisher, network, or station attribution. | Skip most |
| `signoff` | Routine thanks, goodbye, or next-episode farewell. | Skip most |

One span may have multiple reasons. For example, "read The Verge, listen to our
podcasts, subscribe" is both `publisher_promo` and `membership_appeal`.
Playback skips a span when any of its reasons is enabled by the active preset.

Previews, recaps, ordinary show openings, ordinary content, and archival ads are
not removal categories. They remain content and are tested as such.

## Listener experience

Do not expose raw taxonomy or a large switchboard in the first release. Use a
single settings row that opens a small preset picker. The subtitle tells the
listener exactly what each choice does.

```text
Settings
┌──────────────────────────────────────────────────────────┐
│ Automatic skipping                                        │
│                                                          │
│ Skip interruptions              Skip obvious interruptions › │
│ Clear paid ads and sponsor messages                        │
│                                                          │
│ Preview and recap segments are always kept.               │
└──────────────────────────────────────────────────────────┘

Choose what PodWash skips
┌──────────────────────────────────────────────────────────┐
│ ● Skip obvious interruptions                 Default       │
│   Paid ads and sponsor messages                           │
│                                                          │
│ ○ Skip more interruptions                 Experimental     │
│   Also promos and support messages. May remove material   │
│   you would prefer to hear.                               │
│                                                          │
│ ○ Skip most interruptions                  Experimental    │
│   Also follow requests, credits, network IDs, and sign-offs.│
│   May remove material you would prefer to hear.            │
│                                                          │
│ Previews, recaps, and episode content are always kept.    │
└──────────────────────────────────────────────────────────┘
```

Selection persists in `SettingsStore`. It updates the scheduled playback
intervals from cached typed spans immediately. It does not re-download audio,
retranscribe, or call the server.

## API and cache contract

There are no active App Store users requiring compatibility with the old
untyped contract. The backend and iOS app can move to the typed contract in a
coordinated release. Keep schema versioning for cache correctness and debugging,
not to preserve an unused public v1 API.

```json
{
  "status": "complete",
  "schema_version": 2,
  "segments": [
    {
      "start": 4238.22,
      "end": 4250.74,
      "reasons": ["publisher_promo", "membership_appeal"]
    }
  ]
}
```

Server responsibilities:

1. Return all typed spans; never apply an individual listener's preset.
2. Version cache keys by model, prompt, span schema, and transcript HMAC.
3. Preserve exact timestamps and non-overlapping normalized spans.
4. Deploy the typed backend contract before enabling the matching iOS UI.

iOS responsibilities:

1. Add `SkipPreset` and a typed `ContentSegment` reason set.
2. Decode and persist raw typed spans in `EpisodeAnalysisArtifactStore`.
3. Filter cached spans through the active preset before `IntervalBuilder` and
   `IntervalScheduler` create playback intervals.
4. Invalidate old untyped span caches through the cache-version migration; no
   compatibility decoder is required for an unreleased user base.
5. Add the picker to `SettingsView`, persist it in `SettingsStore`, and trigger
   local schedule recomposition when it changes.

Likely iOS touch points are `ContentSegmenting.swift`, `CloudAdSpanClient.swift`,
`EpisodeAnalysisArtifactStore.swift`, `SettingsStore.swift`, `SettingsView.swift`,
`AnalysisPipeline.swift`, `IntervalBuilder.swift`, and their unit/UI tests.

## Golden policy and audit

Move from `ads-only-v1` to `typed-removal-v2`. Goldens must retain a reason set
even when a span is only removable in Skip most interruptions. Profile-specific scoring is
derived from the same typed golden rather than maintaining three incompatible
binary corpora.

Audit workflow:

1. Review every existing golden start/end and assign its typed reason(s).
2. Review all Jev/golden disagreement blocks and commercial-cue candidates
   outside both sets.
3. Review credits, IDs, sign-offs, membership appeals, and promos consistently.
4. Add a random sample of apparently editorial regions as a safety check.
5. Require a reviewer attestation that previews, recaps, feed drops, and
   editorial archival clips were not marked removable.
6. Freeze the corrected development set, then create fresh unobserved holdout
   episodes for final promotion decisions.

The Version History audit is the reference example:

- Duracell and Starbucks midrolls are paid ads and belong in every preset.
- The Verge subscription pitch is `publisher_promo` plus `membership_appeal`.
- The thank-you/sign-off and bare Vox Media production credit are separate
  types, not accidental extensions of the subscription pitch.
- The Philips Living Colors commercial clip remains editorial because the hosts
  introduce it and discuss it as historical evidence.

## Jev v7 candidate

Frozen v6 remains an immutable baseline. The next candidate is a new experiment,
not a hidden prompt change to v6.

1. Include RSS `episodeDescription` along with title and show description.
2. Add explicit positive protection for previews, recaps, and editorially framed
   archival/quoted commercials.
3. Keep the broad first pass: paid promotion vs promotional interruption vs
   keep-content/mixed boundary.
4. Run a second, small subtype pass only for promotional candidates to attach
   one or more typed reasons. This keeps cost bounded and avoids making every
   sentence choose among too many fine-grained labels.
5. Remove v6's diagnostic gap questions from production-shaped requests; they
   did not affect the frozen decision rule and account for substantial request
   overhead.
6. Compare v7 and Gemini on the same corrected episodes and on new holdout
   episodes, reporting every preset separately.

## Verification gates

Before rollout:

- Unit-test preset-to-reason mapping, multi-reason spans, local rescheduling,
  legacy cache reads, endpoint schema compatibility, and settings persistence.
- UI-test all three picker states, accessibility labels/values, and immediate
  playback schedule recomposition.
- Add invariant tests that previews, recaps, feed drops, and framed archival ads
  never become removable under Skip most interruptions.
- Golden-audit every disagreement before threshold tuning.
- Evaluate precision, recall, editorial seconds removed, missed removable
  seconds, and boundary error independently for all three presets.
- Require corrected-corpus and fresh-holdout results before retiring Gemini.
- Run a staged server rollout with typed spans observed in diagnostics before
  enabling typed playback by default.

## Delivery sequence

1. Run Jev v7 on Version History, Planet Money, and Radiolab; review its typed
   output in Golden Retriever and correct the pilot goldens.
2. Freeze the pilot `typed-removal-v2` goldens and validate fresh holdouts.
3. Run Jev v7 against the corrected corpus; validate the lower-cost
   production-shaped request.
4. Implement and deploy the typed server response and cache behavior. No
   production playback changes yet.
5. Implement the iOS typed-span model and preset picker against that deployed
   contract; enable it only after end-to-end verification.
6. Compare Jev with Gemini in shadow mode on fresh episodes, then stage typed
   playback and the preset UI.
7. Remove Gemini only after Jev meets the profile-specific safety gates.

## Non-goals

- No preview or recap skipping, including Skip most interruptions.
- No per-category switchboard in the initial listener UI.
- No reinterpretation of old untyped span caches; invalidate them.
- No production Gemini removal until the typed Jev comparison passes.
