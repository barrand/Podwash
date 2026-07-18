# Ad detection — DAI Phase 1 (existence probe)

**Status:** Spec ready; implement when executing the Phase 1 plan.  
**Parent catalog:** [ad-detection-approaches.md](ad-detection-approaches.md) (approach #1).

## Goal

Answer cheaply, **without ASR**: do two downloads of the same episode audio differ enough to suggest Dynamic Ad Insertion (DAI)?

If yes → later phases can word-diff transcripts. If no → do not invest in double-fetch for that show yet (CDN cache caveat below).

## Out of scope

Word-diff detector, second transcript, REVIEW scoring, app double-download UX, approaches #2–#5.

## Method

For each `tmp/ad-eval/*/meta.json` with `audioUrl` and existing `audio.mp3`:

1. Re-fetch → `audio2.mp3` (reuse patterns from `scripts/ad_eval_fetch.py`).
2. Compare to `audio.mp3`: byte size, SHA-256, decoded duration (`afinfo` / `ffprobe`).
3. Classify:
   - **dai_likely** — duration Δ ≥ ~1s and/or size Δ ≥ ~50KB (tunable)
   - **identical** — same hash (or size+duration within epsilon)
   - **fetch_error**
4. Write `tmp/ad-eval/dai-probe-report.json` and print a markdown table.

**Script (to add):** `scripts/ad_eval_dai_probe.py`

## CDN caveat

Some hosts cache the same fill briefly. One **identical** pair does **not** prove “no DAI,” especially for suspected DAI shows (Cougar, TAL). Optional retry with delay / different User-Agent; log attempts in the report.

## Exit criteria

Report reviewed; list of `dai_likely` shows for a **future** Phase 2 (transcribe `audio2` → word-diff). **Stop after Phase 1.**
