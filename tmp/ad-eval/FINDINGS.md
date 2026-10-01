# Ad-eval findings — heuristic-cue-v6 baseline (2026-07-16)

## Corpus fetched

Listening list + Cougar Sports + TAL **891** (pin) under `tmp/ad-eval/` (gitignored).
TAL 891 transcribed with `faster_whisper:base.en` (11 890 words).

## Diff-label TAL 891

Published transcript: https://www.thisamericanlife.org/891/transcript  
`diff_golden.json` → 18 candidate spans (alignment noise includes some non-ads; treat as **provisional** until spot-check).

Notable spans matching device screenshots:

| Wall | Diff span | Notes |
|------|-----------|-------|
| ~8:36 | 8:36–9:00 | Capital One midroll + host bleed into Act One |
| ~30:54 | 30:57–32:30 | Whole Foods → strawberry.me midroll cluster |

## v5 (span-grow / Python mirror) vs v6 (Swift CLI) on TAL 891

Against provisional diff golden:

| Detector | Seg P/R | Time-weighted P/R | Median Δstart / Δend |
|----------|---------|-------------------|----------------------|
| span-grow (v5) | 0.800 / 0.222 | 0.798 / 0.454 | 2.6 s / 7.0 s |
| swift-cli (v6) | 0.429 / 0.167 | **0.822** / 0.366 | 3.0 s / **3.7 s** |

v6 improves **precision** and **end-boundary** tightness (less bleed); recall vs noisy diff-label is lower — expected until human-reviewed goldens land for the listening corpus.

## v5 trace root-cause (TAL 891)

`python3 scripts/ad_eval_detector.py --trace tmp/ad-eval/this-american-life/transcript.json`

- Anchors fire on `"This message comes from"` and `"following message come from"` (Whole Foods / strawberry).
- Grow merges midroll pods into long ranges (`[1855.67, 1944.45]` ≈ 30:55–32:24) with **weak post-closer stop** — matches end-bleed and late interior gaps.
- Opener tokenization works when the phrase is present; mid-sentence yellow on device is consistent with **block-level density / grow** rather than sentence boundaries (v6 addresses this).

## Fixture gate (shipped)

All synthetic ACs green via `PodWashTests/SegmentationSpikeTests` + `IntervalCacheTests`:

```
VERIFY RESULT: exit=0 total=15 passed=15 failed=0 skipped=0 filtered=1 bundle=build/test-results/verify-20260716-144855.xcresult
```

## Next human step

Spot-check `MARKUP.md` / goldens for AI Daily Brief, AI News & Strategy Daily, Version History, Cougar Sports after `base.en` transcribe + `ad_eval_label.py --no-llm`.
