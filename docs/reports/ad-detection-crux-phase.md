# Ad-detection crux phase (2026-07-22)

## Corpus contract

The benchmark is the 21 tracked `human-approved` `ads-only-v1` goldens. Every
approved span is removable; labels remain diagnostic metadata. The frozen split
is in `eval/ad-detection/corpus-manifest.json`. Scoring rejects a missing or
hash-mismatched local transcript instead of using any proposal or disposable
`tmp` golden.

## Transcript-only result

The shipped `heuristic-cue-v6.1` and the new offline-only
`anchor-viterbi-v1` were scored through the same Swift CLI. The committed JSON
results contain the per-episode details and failure packets live only in
`tmp/ad-eval/failure-packets/`.

On the frozen holdout, Viterbi increases ad coverage but also increases
false-positive content loss compared with v6.1. It therefore **does not pass**
the promotion rule and is not wired into `ProductionAnalyzerFactory`.

The useful conclusion is narrow: a global decoder is viable and measurable,
but its current transition/emission settings are unsafe for podcast playback.
Future tuning must use only the development split and retain the same holdout.

## DAI probe

`scripts/ad_eval_dai_probe.py` makes two fresh no-cache requests per corpus
episode, records response identity and decoded duration, and writes only local
extra audio under `tmp`. A hash change is `dai_likely` only with a material
duration or size difference; identical copies remain `inconclusive`.

No second ASR, word diff, or app download behavior is part of this phase.
