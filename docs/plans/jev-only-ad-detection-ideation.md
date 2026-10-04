# Jev-Only Ad Detection: Ideation and Experiment Map

Status: **living design note, not an approved production plan**.

This document keeps promising ideas and failed hypotheses visible while we
explore replacing Gemini with Jev. Fixed experiment protocols and results
belong in separate evaluation plans so this note can change without rewriting
the historical record.

## Product decision

The system must find complete removable ad spans while minimizing deletion of
editorial content. False-positive content loss is more harmful than leaving a
few ad seconds behind. The useful question is therefore not merely "is this
sentence ad-like?" but:

> Can PodWash remove this contiguous passage without deleting material the
> listener reasonably intended to hear?

Routine opening/closing material and requests to subscribe to, rate, or review
the current show remain keep-content unless product policy changes explicitly.

## Evidence so far

- Jev 1.13 is fast and inexpensive enough for multi-stage evaluation.
- The original single `Noul` for removable advertising remains the strongest
  sentence-level baseline.
- Splitting paid ads and promos into independent `Noul`s and taking their
  maximum made results worse. It introduced promo-shaped false positives and
  did not recover the difficult network promo.
- Clear host-read ads score strongly. Generic fragments, ad transitions, and
  network bumpers need surrounding sequence context.
- An exploratory high-confidence-seed/lower-continuation rule improved v2
  precision from 0.970 to 0.990 at the same 0.937 recall on the micro sample.
  This is post-hoc evidence, not a valid final benchmark result.
- Scores for duplicate sentences can move when their context window changes.
  Production must give each decision one canonical context.
- The evaluator and shipped iOS client currently use different sentence
  segmentation. They must be identical before a production comparison.

### Role-Choice v3 result

The frozen 33-window v3 run completed on 2026-10-01 using Jev 1.13.0:

- cost: $0.0068163;
- median/max latency: 191.6/364.7 ms;
- at threshold 0.50: precision 0.9928, recall 0.9281, 6.22 false-positive
  seconds, and 66.70 missed-ad seconds;
- at threshold 0.70: precision 1.0000 and recall 0.9140;
- maximum removable probability in the no-ad control: 0.02;
- no purely editorial sentence reached 0.50; the 6.22 false-positive seconds
  at 0.50 came from the editorial portions of mixed boundary sentences;
- fully-ad sentences alone had 0.9786 recall at 0.50. About 47.94 of the
  66.70 missed seconds were ad portions of mixed boundary sentences.

The competing roles successfully protected routine housekeeping: the v2 false
positive asking listeners to download, rate, and review the current show fell
from 0.80 removable probability to 0.00. However, the Cougar Sports station
bumper also fell to 0.05 because the v3 policy described current-show/station
identification as housekeeping while its golden labels that produced bumper as
removable. Resolve that policy contradiction before another prompt revision.

V3 is the strongest safety-oriented semantic design so far, but it is not yet a
standalone production result. Its aggregate recall is limited mainly by mixed
sentence boundaries, one prompt/golden policy conflict, and unstable context
for generic ad openers. The next experiment must use the exact production
segmenter and one canonical context per decision.

### Production-boundary v4 result

The 33-window v4 run completed on 2026-10-02 using exact iOS segmentation,
the revised removable-bumper role, and gap-transition choices:

- cost: $0.01157197;
- median/max latency: 228.0/390.4 ms;
- using one combined 0.50 threshold: precision 0.9800 and recall 0.9511;
- clean no-ad control maximum removable probability: 0.07;
- the previously missed Cougar Sports station bumper scored 0.97 removable;
- all pure-editorial false positives came from the bumper class, not paid-ad
  classification;
- separate thresholds of 0.50 for paid ads and 0.90 for bumpers produced
  precision 0.9963 and recall 0.9492, with no pure-editorial false positive;
- fully-ad sentence recall under those separate thresholds was 0.9920;
- Jev selected all 8 clean ad starts correctly and 8 of 9 clean ad ends;
- overall gap accuracy was 0.8974, but only 2 of 16 gaps adjacent to mixed
  sentences were labeled uncertain/mixed.

The main remaining loss is representational, not semantic. The production
splitter can create long sentences containing both editorial and ad material.
For example, one 27-second Cougar Sports sentence combines a guest list with a
closing sponsor appeal. Jev safely labels it mixed, but the current server
contract has no finer timestamp at which to cut it. Before expanding the
corpus, test a production-compatible maximum-duration split using the original
timed words. A server-only provider swap remains possible at current quality;
improving mixed-boundary recall likely requires one client segmentation update
or a richer word-timestamp request contract.

### Duration-capped v5 result

The frozen v5 run completed on 2026-10-02 with the production rules plus an
18-second duration cap and the precommitted paid=0.50/bumper=0.90 decision rule:

- precision 1.0000 and recall 0.9587;
- 0.00 false-positive seconds and 38.84 missed-ad seconds;
- no-ad control maximum removable probability: 0.05;
- cost: $0.01164201; median/max latency: 199.1/360.8 ms;
- fully-ad sentence recall: 0.9825;
- every mixed sentence was conservatively retained, accounting for 22.80
  missed-ad seconds; fully-ad fragments accounted for the remaining 16.04;
- all 8 clean starts and 8 of 9 clean ends were selected correctly;
- overall gap accuracy improved to 0.9124 and mixed-gap accuracy improved from
  2/16 in v4 to 5/16.

Against v4 under the same paid/bumper rule, v5 removed the remaining 3.30
false-positive seconds and recovered 8.92 ad seconds. Do not tune further on
the same three episodes. They are in the corpus's nominal holdout and have now
been used repeatedly for Jev design. Freeze v5 and run complete, non-golden-
selected scans on episodes not used during Jev prompt development.

## Leading Jev-only architecture

Use Jev for semantic decisions and deterministic server code for coverage,
sequencing, and span construction.

1. **Canonical segmentation**
   - Reproduce the production sentence rows exactly on the server and in the
     evaluator.
   - Divide an episode into overlapping windows, but score each sentence in
     exactly one window's central region.

2. **Coarse semantic pass**
   - Ask one mutually exclusive `Choice` per target sentence or small target
     block: `paid_ad`, `cross_promo`, `routine_housekeeping`,
     `editorial_content`, or `mixed_boundary`.
   - Preserve the entire probability distribution. Candidate removable
     probability is `P(paid_ad) + P(cross_promo)`, not the maximum of
     independent questions.
   - Keep the original single removable-ad `Noul` as the control design.

3. **Sequence decoder**
   - Require a high-confidence sentence to seed an ad run.
   - Admit lower-confidence neighboring sentences only as continuation of an
     established run.
   - Optionally bridge one short ambiguous fragment when strong ad evidence
     exists on both sides.
   - Never create a removable span from one isolated medium-confidence result.

4. **Boundary pass**
   - Around each proposed start and end, ask a `Choice` about the gap:
     `ad_begins`, `ad_ends`, `same_ad_continues`,
     `same_editorial_continues`, or `uncertain_or_mixed`.
   - Ask a safety `Noul`: would removing the proposed block delete substantive
     editorial content?
   - Trim or reject unsafe spans in code.

5. **Span output**
   - Merge adjacent compatible runs, reject invalid durations, and return the
     same time-span contract the iOS app already consumes.
   - Keep all provider keys, prompts, thresholds, and model versions on the
     server. A provider swap should not require an iOS update unless the API
     contract changes.

This is Jev-only in the model layer: no Gemini call is needed. Conventional
code remains responsible for ensuring complete transcript coverage and
turning probabilities into safe contiguous spans.

## Next experiment: role choice versus the baseline

Run the smallest discriminating test before building the complete pipeline.
Reuse the exact frozen v2 windows and goldens, and add one `Choice` question per
target:

```json
{
  "type": "choice",
  "instructions": {
    "task": "Classify the primary role of the target sentence. Use neighboring text only to interpret the target.",
    "removal_policy": "When a sentence mixes removable promotion and substantive program content, select mixed_boundary."
  },
  "criteria": {
    "paid_ad": "Paid commercial, host-read sponsor, dynamic ad, disclaimer, or commercial call to action.",
    "cross_promo": "Explicit promotion for another show, network property, membership, event, or fundraiser.",
    "routine_housekeeping": "The current show's ordinary identification, opening, closing, credits, or request to subscribe, rate, or review.",
    "editorial_content": "Substantive discussion, reporting, interview, or storytelling, including ordinary discussion of a company or product.",
    "mixed_boundary": "The sentence contains both removable and keep-content or cannot be safely removed as a whole."
  }
}
```

Compare three frozen designs on identical targets:

1. Original single removable-ad `Noul`.
2. The failed paid/promo max-OR v2 design.
3. The new mutually exclusive role `Choice`.

Before seeing results, define `P(removable) = P(paid_ad) + P(cross_promo)` and
treat `mixed_boundary` as keep-content for automatic removal. Sweep fixed
thresholds; do not tune a bespoke threshold per episode.

The experiment answers one focused question: does forcing ad, editorial,
housekeeping, and mixed content to compete reduce false positives without
losing the strong ad recall of the original Noul?

## Follow-on experiments

Run these only if the role-choice result is useful:

1. **Sequence decoding:** compare a plain threshold with high seed/low grow,
   neighbor support, and one-fragment bridging. Select rules on development
   episodes only.
2. **Boundary choices:** ask transition questions at proposed span edges and
   measure start/end overrun separately.
3. **Removal safety:** test whether a substantive-content Noul rejects mixed
   and editorial spans that otherwise look promotional.
4. **Context ablation:** compare local text alone with episode metadata,
   timing/silence features, and deterministic commercial cues.
5. **Full-episode discovery:** scan complete development episodes, including
   hard negatives, rather than windows selected using golden locations.
6. **Frozen holdout:** lock prompts, thresholds, sequence rules, model revision,
   and segmentation before evaluating untouched episodes.

## Later ideas

- Detect repeated transcript blocks across episodes; recurring blocks are
  strong candidates for ads, network bumpers, intros, or outros. Ask Jev to
  distinguish those roles.
- Add structured signals such as silence gaps, speaker changes, URLs, promo
  codes, prices, disclaimers, and repeated-copy indicators to Jev state.
- Use two context scales only for uncertain cases: a local boundary window and
  a larger rhetorical block.
- Escalate low-confidence spans to a second Jev formulation rather than asking
  every sentence multiple redundant questions.
- Keep a conservative mode that removes only unmistakable paid-ad runs and a
  more aggressive mode only if the product later exposes that choice.

## Evaluation requirements

The final comparison must report product-shaped outcomes, not only sentence
precision and recall:

- editorial seconds deleted per listening hour;
- ad seconds left per listening hour;
- harmful cuts per episode;
- start- and end-boundary overrun/underrun;
- complete-ad-block capture rate;
- probability calibration;
- results by ad subtype and hard-negative category;
- latency and cost per listening hour.

The development set must include difficult non-ads: product discussion, guest
plugs, current-show housekeeping, station IDs, credits, jokes that sound like
ads, fundraising discussed editorially, and sentences that straddle true
boundaries.

## Open policy decisions

- Are cross-promotions for another show always removable?
- Are network/station IDs removable when they contain no call to action?
- Are current-show subscription or membership appeals removable?
- Should a mixed sentence always be kept, or may a future finer-grained
  segmenter split it?
- What relative penalty should evaluation assign to one second of deleted
  editorial content versus one second of missed advertising?

## Audit-derived policy draft: classify first, filter second

Do not use "unrelated to the episode topic" as the removal rule. Topic drift is
useful supporting evidence, but by itself would wrongly remove tangents, quoted
material, credits, guest discussion, and documentary examples. Classify the
speaker's function and commercial intent first, preserve that category in the
server response, and let listener settings decide which categories to skip.

| Category | Classification rule | Suggested default |
| --- | --- | --- |
| Paid ad | A current commercial, sponsor read, DAI creative, disclaimer, or CTA. | Skip |
| Cross-show/network promo | A produced teaser or explicit invitation to consume another show or network property. | Listener setting |
| Membership/subscription appeal | An explicit request to pay, subscribe, donate, or join an ad-free feed, including its value statement. | Listener setting |
| Current-show housekeeping | Follow/rate/review requests, schedule notes, thanks, greetings, and ordinary sign-offs without a paid conversion pitch. | Keep |
| Production credit/network ID | Identity or attribution without a promotional claim or listener action. | Keep |
| Quoted or archival commercial | Commercial material played as the object of reporting, criticism, history, or discussion, with nearby editorial framing. | Keep |
| Mixed boundary | One model sentence contains both removable and keep material. Split deterministically when possible; otherwise keep the whole sentence. | Keep safely |

Applied to the Version History outro: remove the explicit "subscribe to The
Verge" appeal through "It's what enables us to do all of this stuff." Keep
"Thank you so much," "We'll see you next time," and the bare Vox Media
production credit. Applied to the Philips Living Colors clip: keep it because
the host explicitly introduces and discusses the historical commercial as
episode evidence.

The next Jev candidate should add the RSS episode description, explicitly teach
the quoted/archival-commercial exception, and split the current broad promo role
into typed promotional outputs. This is a new experiment; frozen v6 and its raw
artifacts remain unchanged.

**Preset decision (2026-10-04):** listener-facing settings are Skip obvious
interruptions, Skip more interruptions, and Skip most interruptions. **Skip
obvious interruptions is the default.** Skip more and Skip most are labelled
**Experimental** with the plain-language warning “May remove material you would
prefer to hear.” Previews and recaps are editorial invariants and are never
removable, including under Skip most interruptions. The detailed taxonomy, API,
cache, and iOS plan lives in [`typed-removal-presets.md`](typed-removal-presets.md).

## Decision log

| Date | Decision or finding |
| --- | --- |
| 2026-10-01 | Keep the single removable-ad Noul as the sentence-level baseline. |
| 2026-10-01 | Reject paid/promo max-OR v2 as the leading design. |
| 2026-10-01 | Explore a fully Jev-only model layer with deterministic sequence and boundary logic. |
| 2026-10-01 | Role Choice v3 achieved P=0.9928/R=0.9281 at 0.50 with no pure-editorial false positive; retain it as the leading safety-oriented design. |
| 2026-10-01 | Next resolve station-bumper policy and test exact production segmentation plus canonical context. |
| 2026-10-02 | Implement v4 with exact iOS segmentation, a distinct removable-bumper role, and explicit gap-transition choices; live run pending. |
| 2026-10-02 | V4 achieved P=0.9963/R=0.9492 with paid=0.50 and bumper=0.90; clean boundaries were 16/17 correct. |
| 2026-10-02 | Treat long mixed production sentences as the next bottleneck; test a duration cap before broad corpus evaluation. |
| 2026-10-02 | Implement v5 with an 18-second production duration cap and freeze paid=0.50/bumper=0.90 before the live run. |
| 2026-10-02 | Frozen v5 achieved P=1.0000/R=0.9587 and improved both editorial safety and ad recall over v4. |
| 2026-10-02 | Stop tuning on the three micro episodes; next run complete episodes with v5 unchanged. |
| 2026-10-02 | Implement frozen v6 full scans over all 12 Jev-untested development episodes; each sentence and gap is targeted exactly once. |
| 2026-10-02 | Golden audit found missing Duracell and Starbucks midrolls in Version History and an overlong membership-CTA boundary; corrected both while keeping frozen v6 outputs unchanged. |
| 2026-10-02 | Draft typed removal policy: classify paid ads, cross-promos, and membership appeals separately; keep ordinary sign-offs, bare credits, and editorially framed archival commercials. |
| 2026-10-04 | V8 two-minute scout covered all 16 paid spans and 100% of paid seconds, but the frozen 0.20 threshold failed on a protected Dr. Death feed-drop promo. Keep V8 rejected; validate a separately frozen V8.1 at 0.85 with explicit feed-drop protection, first on locked regressions and then on a fresh human-labeled holdout. |
| 2026-10-04 | V8.1 Stage 0 passed its four frozen boundary cases. Stage 1 then hit all 30 approved paid spans and the no-ad control, but formally failed on two Unexplainable windows containing “This series is presented by Comcast Business” inside a `network_promo` golden. Preserve the model output and adjudicate that sponsor tag in the golden before any rerun, threshold change, or holdout. |
| 2026-10-04 | Human adjudication split the 2.34-second Comcast Business sponsor acknowledgement from the surrounding Unexplainable network promo into `paid_ad`. Rescoring the immutable V8.1 Stage 1 responses made no new requests and passed all gates: 31/31 paid spans, 100% paid seconds, zero true-control or promo-only positives, and 16.4% coverage. Proceed to the untouched Stage 2 holdout. |
