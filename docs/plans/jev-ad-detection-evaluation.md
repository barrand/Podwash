# Jev Ad-Detection Micro-Evaluation

Status: **approved for an offline feasibility run; no production or iOS changes**.

## Decision being made

Decide whether Jev understands PodWash's sentence-level distinction between
removable podcast advertising and editorial speech well enough to justify a
full-corpus comparison with Gemini. This run cannot approve Jev for production.

The first whole-episode request was rejected by TypeSafe with
`max_tokens_exceeded`. Jev 1.13 accepts at most 64k tokens per request and at
most 32k tokens for state plus the longest question. Large unrelated state can
also reduce accuracy. The micro-evaluation therefore sends small, labeled
transcript windows rather than entire episodes.

## Implementation boundary

Use one standalone Python command under `scripts/`. It reads the tracked,
hash-pinned transcripts and human-approved goldens, contacts only TypeSafe's
official System One endpoint, and writes local artifacts under the gitignored
`tmp/ad-eval/jev-micro-v2/` directory.

Run it through `scripts/run_ad_eval_jev.ps1`, which prompts for the API key
without echoing it, caches it only in the current PowerShell process, performs
the dry-run, and requires an explicit `YES` before the live evaluator. Later
runs in the same terminal reuse the key; closing the terminal clears it.

Do not change the iOS app, backend, production provider, consent, privacy
disclosure, cache, or listener behavior. Do not upload audio.

## Fixed model and sample

Pin `jev-1.13.0`; do not use a moving model alias.

Generate a deterministic sample before any response is observed:

- one window around every approved ad span in `cougar-sports` (10 windows);
- one window around every approved ad span in `joe-rogan-mrbeast` (13 windows);
- ten evenly spaced windows from the zero-ad
  `ai-news-strategy-daily` control.

Each positive window asks about every sentence overlapping the approved ad plus
two sentences before and after. Eight additional sentences on each side are
included as context but are not scored. Each no-ad window asks about five
central sentences with eight context sentences on each side. Duplicate target
sentences are de-duplicated by episode and sentence ID in aggregate metrics.

This selection deliberately uses golden knowledge. It is a feasibility test,
not an unbiased benchmark.

## Jev interaction

Send structured state containing show/episode context and the local ordered
sentence window. Batch two independent `Noul` questions per target sentence in
the request:

1. Is sentence ID N part of a paid commercial or sponsor read?
2. Is sentence ID N part of a removable station, network, show, membership, or
   fundraising promotion?

The first Noul covers paid commercials, host-read sponsors, and inserted ads.
The second covers network/cross-promos and membership/fundraising CTAs. Both
include their openers, disclaimers, and calls to action while excluding show
content, ordinary discussion, credits, and non-promotional introductions or
closings. Transcript text is data, never instructions.

Record both raw Noul probabilities and define the sentence's combined ad
probability as their maximum (a deterministic OR). Do not pick or tune one
production threshold in this run. Report a fixed sweep at 0.50, 0.70, 0.80,
0.90, and 0.95 so the precision/recall and editorial-loss tradeoff is visible.

## Artifacts and review

For every window, save the exact request, response, request hash, resolved model
revision, latency, usage, cost, and parsed sentence probabilities. The command
is resumable: an existing result is reused only when its request hash matches.

Write:

- `manifest.json` — the complete deterministic sample and request sizing;
- `report.json` — de-duplicated observations and threshold metrics;
- `REVIEW.html` — sentence text, golden overlap, and Jev probability for manual
  inspection;
- per-window request, response, and result files.

The report is promising only if there is a threshold region with strong ad
recall, no high-probability prediction in the no-ad control, and no obvious
editorial boundary sentences receiving high ad probability. The reviewer must
inspect the probability transition at every ad start and end.

If promising, write a separate full-corpus plan: select thresholds only on the
development split, freeze them, then compare Jev and Gemini on identical
sentence rows in the holdout split. If not promising, stop.

## Safety and verification

- Enforce a hard US$1 spend cap before and during the run.
- Stop on provider errors; do not retry automatically.
- Reject requests conservatively estimated above 20k tokens.
- Validate exact answer IDs, Noul types, probabilities, usage, transcript
  hashes, and the pinned response model.
- Unit-test deterministic sampling, request construction, response parsing,
  threshold scoring, and Windows/LF transcript hash equivalence.
- Never print transcript text or the API key.

## Non-goals

- No full episodes or full-corpus benchmark in this run.
- No Gemini API calls or production-provider decision.
- No ad-subtype classification, generated boundary ranges, or prompt tuning.
- No server or iOS implementation.
