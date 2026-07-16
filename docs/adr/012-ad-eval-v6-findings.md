# Ad-eval findings — heuristic-cue-v6 baseline (2026-07-16)

Committed copy of Phase 0 notes (full working tree under gitignored `tmp/ad-eval/`).

## Corpus

Listening list + Cougar Sports + TAL **891** fetched. TAL 891 transcribed with `faster_whisper:base.en`.

## TAL 891 provisional metrics (diff-label golden)

| Detector | Time-weighted P | Time-weighted R | Median Δend |
|----------|-----------------|-----------------|-------------|
| v5 span-grow | 0.798 | 0.454 | 6.96 s |
| v6 swift-cli | **0.822** | 0.366 | **3.69 s** |

v6 tightens ends (less bleed). Corpus 0.98/0.95 worst-episode gate awaits human-reviewed goldens.

## Fixture gate

See `ad-eval-metrics-v6-evidence.json` and slice-34 verification record.
