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

## Decision log

| Date | Decision or finding |
| --- | --- |
| 2026-10-01 | Keep the single removable-ad Noul as the sentence-level baseline. |
| 2026-10-01 | Reject paid/promo max-OR v2 as the leading design. |
| 2026-10-01 | Explore a fully Jev-only model layer with deterministic sequence and boundary logic. |
| 2026-10-01 | Next proposed test is mutually exclusive role Choice on the frozen micro sample. |
