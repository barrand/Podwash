# Jev V7 typed-interruption pilot

**Status:** V7 and V7.1 completed; V7.2 completed and rejected
**Episodes:** Version History, Planet Money, Radiolab  
**Recommended output:** `tmp/ad-eval/jev-typed-v7.1/report.json`  
**Rejected V7.2 output:** `tmp/ad-eval/jev-typed-v7.2/report.json`

V7 validates whether Jev can produce the complete typed interruption set needed
by the three listener presets. It is evaluation-only and changes neither the
production backend nor iOS playback.

## Request shape

1. A broad pass evaluates every sentence as removable candidate, protected
   editorial, editorial content, or mixed boundary.
2. Only candidate sentences receive a subtype pass.
3. The subtype pass asks independent questions for all nine reason types, so a
   sentence may retain multiple reasons.
4. Every request includes show title, episode title, show description, RSS
   episode description, nearby transcript context, and an explicit untrusted
   text boundary.
5. Preview, recap, feed-drop, substantive editorial, and editorially framed
   archival-ad protections are repeated in both passes.
6. V6 diagnostic gap questions are omitted.

## Review and decision

Golden Retriever prefers V7 output automatically when its report exists. The
typed audit remains the provisional reference; it is not silently rewritten by
the experiment. Review every V7/reference disagreement, then correct and freeze
the pilot goldens before adding holdout episodes.

V7 showed that the broad candidate pass retained approximately 99–100% of the
pilot reference material, while independent per-sentence subtype questions were
badly under-confident. V7.1 therefore reuses the paid-for broad responses,
recursively splits mixed candidate runs into coherent blocks, assigns the
minimum listener preset to each block, and then assigns reasons to the complete
block. It never reruns the broad pass.

Report precision, recall, false-positive seconds, and missed seconds for every
reason and for all three listener presets. Editorial content removed under any
preset is the primary safety failure.

## Run

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run_ad_eval_jev_v7.ps1
```

The launcher performs a dry run first, prompts before network requests, reuses
matching cached results, and caps total spend at $0.50.

Run the block-level follow-up with:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run_ad_eval_jev_v71.ps1
```

The V7.1 follow-up has a separate $0.25 incremental cap and writes
`tmp/ad-eval/jev-typed-v7.1/report.json`. Golden Retriever prefers that report
over V7 and V6 when it exists.

## V7.2 focused refinement

V7.2 reuses both completed reports and addresses the observed V7.1 failure
modes without changing the provisional typed goldens:

1. Re-evaluate every V7.1 span sentence by sentence, including three sentences
   on either side, so oversized boundaries can shrink and short internal promo
   gaps can be restored.
2. Keep previews and recaps protected, while clarifying that quoted dialogue or
   sample clips enclosed by an unmistakable inserted promo remain removable.
3. Strictly confirm isolated `skip_most_only` sentences to reject punctuation,
   source attribution, speaker introductions, and ordinary conversation.
4. Allow the diagnostic reason to be `uncertain` when no reason has at least
   50% support. The minimum skip preset remains the product-critical output.

Run it with:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run_ad_eval_jev_v72.ps1
```

The launcher reuses cached results, performs a dry run first, has a separate
$0.15 incremental cap, and writes `tmp/ad-eval/jev-typed-v7.2/report.json`.

### V7.2 outcome

Reject V7.2. Its sentence-level `noul` boundary questions produced nearly flat
probabilities across each requested window rather than discriminating sentence
boundaries. It simultaneously expanded some detections into surrounding
editorial content and dropped complete real ads that fell just below the 0.50
cutoff. Aggregate preset precision/recall regressed from V7.1's 89.5%/99.1%,
82.0%/93.9%, and 80.3%/94.6% to 60.8%/71.5%, 55.6%/75.0%, and 61.4%/77.1%.
Golden Retriever therefore continues to prefer V7.1.

## Rejected custom Gemini typed comparison

Do not use `ad_eval_gemini_typed.py` to decide whether Jev replaces production
Gemini. It changed the production Gemini prompt into a typed-policy prompt with
RSS context and listener presets, so its partial output is not comparable to
the deployed paid-ad detector.

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run_ad_eval_production_gemini_parity.ps1
```

The production-parity harness mirrors `backend/app/main.py`: the production
prompt, production sentence splitter, zero-based IDs, two-field response
schema, model, 8192-token generation setting, and chunking policy. It scores
production Gemini and Jev V7.1 `skip_obvious` against the same approved
ads-only goldens, and writes
`tmp/ad-eval/production-gemini-parity-v1/report.json`. It does not alter
goldens, the backend, or iOS behavior.

## Historical Gemini-v1 baseline comparison

The five holdout episodes in `tmp/ad-eval/gemini-v1` already have saved Gemini
results. Run Jev's V7.1 decision path on those exact transcripts without
calling Gemini again:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run_ad_eval_jev_v71_gemini_v1.ps1
```

This uses V7.1's broad-candidate pass and recursive block tier classifier. It
omits only the final reason-label request, because the comparison is limited to
the ads-only `skip_obvious` output and reasons do not affect that decision. It
writes `tmp/ad-eval/jev-v71-gemini-v1/report.json`, with per-episode and
aggregate Jev versus saved-Gemini scores against the same approved goldens.

It is a useful historical-baseline comparison, not a claim of exact production
parity: the saved Gemini-v1 evaluator used an earlier prompt and sentence
splitter. The separate production-parity harness above remains the test for
the deployed Gemini contract.
