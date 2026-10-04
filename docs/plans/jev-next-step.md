# Jev next step: conservative paid-ad confirmation

## Goal

Keep Jev V7.1's stronger paid-ad recall while reducing false positives enough
to make it a viable replacement candidate for Gemini.

## What we learned

On the five historical Gemini-v1 holdouts, Jev achieved 90.2% recall versus
Gemini's 87.3%, but removed 119.5 seconds of content versus Gemini's 89.2.
Its clearest errors were isolated, non-ad sentences incorrectly emitted as
`skip_obvious`.

## Experiment

1. Reuse the completed V7.1 candidate/block results in
   `tmp/ad-eval/jev-v71-gemini-v1`; do not rerun broad detection.
2. For every proposed `skip_obvious` span, ask Jev one block-level,
   structured confirmation: is the complete block a paid ad or underwriting?
   Include local transcript context and retain the existing preview/recap
   protections.
3. Remove a span only when confirmation is positive. Keep it otherwise.
   Do not use a global confidence cutoff.
4. Score the resulting spans against the same five approved ads-only goldens
   and compare directly with saved Gemini-v1 and unfiltered Jev V7.1.

## Pass criteria

- Lower Jev content loss below Gemini's 89.2 seconds.
- Retain at least Gemini's 87.3% duration-weighted recall.
- Zero false positives in `ai-news-strategy-daily`.
- Review every changed span before any production decision.

## Boundaries

Evaluation only: no iOS/backend changes, no golden edits, and no new Gemini
requests. This remains a historical-baseline comparison; run the separate
production-parity Gemini test before replacing production Gemini.
