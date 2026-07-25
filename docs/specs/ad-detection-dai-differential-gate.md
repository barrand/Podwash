# DAI differential gate

**Status:** implementation complete; evidence run in progress.

## Crux

Can one extra download and one extra on-device ASR pass identify dynamic ads in
the listener's original copy with at least 0.98 all-removable precision and 0.75
dynamic-ad recall, without exceeding the content-loss budget?

The frozen episode split and numeric gate live in
`eval/ad-detection/dai-differential-gate.json`. Approved goldens remain
immutable. The candidate is always original versus copy A; copy B measures
repeatability and cannot become the selected production policy.

## Commands

```sh
# Sequential and resumable; skips transcripts with complete provenance.
python3 -u scripts/ad_eval_dai_diff.py prepare

# Build the unchanged shipped baseline, then reveal the frozen gate.
scripts/build_segmenter_cli.sh
python3 scripts/ad_eval_dai_diff.py gate \
  --swift-cli build/segmenter-cli \
  --output eval/ad-detection/dai-differential-results.json
```

Raw alternate audio, transcripts, provenance, and HTML/JSON failure packets
remain under `tmp/ad-eval/`. Only the compact gate result and this evidence
summary are tracked.

## Safety rules

- Exact ASR engine, model revision, prompt, timestamp, temperature, and coverage
  provenance is required before alignment.
- AI News Strategy Daily is re-transcribed on both original and copy A because
  its approved transcript predates the pinned MLX pipeline.
- Both unchanged/no-ad controls must produce no candidate span of five seconds
  or longer before development tuning is accepted.
- Validation settings are frozen after development selection. No advertiser,
  show-title, or episode-specific rules are permitted.
- Passing this gate does not authorize app download, retention, or scheduling
  changes.
