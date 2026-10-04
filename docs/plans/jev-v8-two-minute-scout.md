# Jev V8 two-minute paid-ad scout

**Status:** V8 completed and rejected at its frozen threshold; V8.1 validation
protocol approved but not implemented

V8 tests one question: can Jev detect that a paid ad exists somewhere inside
an overlapping two-minute transcript window? It does not localize ads, produce
playback spans, classify non-ad interruption types, or change production.

## V8 frozen run and result

V8 scanned Armchair Expert, This American Life, and the no-ad Dr. Death control
using 120-second windows with a 60-second stride. Each request contained one
paid-ad-presence Noul, two surrounding context sentences, and a precommitted
positive threshold of 0.20.

It hit all 16 approved paid-ad spans and covered 100% of approved paid-ad
seconds while flagging 17.4% of listening time. It failed only the control gate:
Dr. Death produced five positive windows. Two high-scoring windows (0.80 and
0.77) contained a cross-show/feed-drop introduction with an Audible ad-free
subscription call to action. The remaining control positives scored 0.28 or
lower.

The run remains formally rejected; its 0.20 threshold must not be changed
post-hoc. Diagnostic scoring showed that thresholds from 0.81 through 0.90
would have retained all paid spans and paid seconds while producing zero
Dr. Death positives. This is development evidence for a separately frozen
V8.1 protocol, not a reinterpretation of V8.

The V8 launcher remains available for reproducing the frozen run:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run_ad_eval_jev_v8.ps1
```

Its artifacts are in `tmp/ad-eval/jev-chunk-scout-v8/`.

## V8.1 frozen protocol

Keep V8's 120-second windows, 60-second stride, two context sentences, pinned
`jev-1.13.0` model, caching, and request validation. Change only the following
before any V8.1 response is observed:

1. Freeze the positive threshold at **0.85**.
2. Clarify that the true class is a current third-party paid commercial,
   sponsor read, DAI creative, or underwriting message.
3. Explicitly make cross-show promos, feed-drop introductions or samples, and
   calls to listen or subscribe to the promoted show false, including an
   ad-free subscription pitch, unless a distinct third-party sponsor message is
   present.
4. Write to a new `tmp/ad-eval/jev-chunk-scout-v8.1/` artifact directory. Never
   reuse or overwrite V8 requests or results.

V8.1 remains a presence scout only. It must not localize boundaries, produce
playback spans, classify the broader presets, or change production behavior.

## Stage 1: locked regression validation

Run the unchanged V8.1 protocol across these six existing approved episodes:

- Bill Simmons / Kawhi — paid-only, long conversational and inserted ads;
- Economics of Everyday Things — paid-only;
- Darknet Diaries — paid ads plus membership material;
- 99% Invisible — paid ads plus network promos;
- Unexplainable — paid ads, membership material, and network promos;
- AI News Strategy Daily — zero-paid-ad control.

These episodes were not used to choose V8's threshold, but some influenced
earlier Jev work. Treat this as a regression test, not a clean holdout. Do not
tune the prompt, threshold, window geometry, or policy from its results. If any
gate fails, reject V8.1 and write a new experiment plan before another paid run.

The regression passes only when:

- every approved `paid_ad` span overlaps a positive window;
- at least 99% of approved paid-ad seconds are inside positive coverage;
- AI News Strategy Daily has zero positive windows;
- every promo-only window—overlapping `network_promo` or `membership_cta` but
  no `paid_ad`—is negative;
- positive coverage is no more than 40% of total listening time; and
- all requests stay below 20k estimated tokens and the preflight spend cap.

Report paid-span coverage, paid seconds covered, positive coverage fraction,
zero-ad positives, promo-only positives, maximum probability by negative class,
cost, and latency. The report must list every positive window and every window
overlapping a paid or protected promotional span.

## Stage 2: fresh promotion holdout

Only after Stage 1 passes, freeze its complete V8.1 manifest and prepare six
new episodes that have never been used for Jev prompt, threshold, or policy
work:

- four paid-ad episodes spanning conversational host reads, DAI, public-radio
  underwriting, and sports/baked-in delivery;
- one true no-ad/no-promo control; and
- one no-paid-ad episode containing a cross-show or feed-drop promotion with a
  subscription call to action.

The holdout must contain at least 20 human-approved paid-ad spans in aggregate.
Human review must label paid ads, underwriting, network/cross-show promos,
membership CTAs, feed-drop material, archival ads, previews/recaps, and
editorial product discussion before any Jev request is made. Pin transcript and
golden hashes in the manifest.

Run the exact Stage 1 V8.1 requests and threshold without alteration. Apply the
same gates, plus zero positive windows in both no-paid-ad controls. Any failure
rejects V8.1 for production scouting; do not tune on the holdout.

Passing both stages establishes only that the two-minute scout is viable. The
next experiment must separately validate localization of exact typed spans
before V8 can affect listener playback or replace Gemini.
