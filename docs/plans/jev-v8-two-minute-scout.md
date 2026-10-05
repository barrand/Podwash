# Jev V8 two-minute paid-ad scout

**Status:** concluded research; not part of the Jev MVP runtime. V8.1's scout
passed, but V8.2-V8.4 did not establish a production playback localizer. See
`docs/plans/jev-mvp.md` for the active implementation plan.

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

## Stage 0: smallest boundary test

Before scanning more full episodes, test the proposed V8.1 separation mechanism
on the four saved V8 windows closest to the new 0.85 decision boundary:

| Expected class | Window | Range | V8 probability |
| --- | --- | ---: | ---: |
| protected promo | `dr-death-w0001` | 0-120s | 0.80 |
| protected promo | `dr-death-w0002` | 60-180s | 0.77 |
| paid ad | `this-american-life-w0030` | 1740-1860s | 0.86 |
| paid ad | `armchair-expert-grant-achatz-w0034` | 1980-2100s | 0.89 |

Run exactly four new requests using the frozen V8.1 wording and threshold. Write
them to `tmp/ad-eval/jev-chunk-scout-v8.1-boundary/`; do not reuse V8 responses
because the classification policy changed. Cap the run at $0.005.

The implementation dry run selected all four frozen windows, estimated the
largest request at 2,501 conservative tokens, and projected a maximum cost of
$0.000396. The focused runner and its secure PowerShell launcher are
`scripts/ad_eval_jev_v81_boundary.py` and
`scripts/run_ad_eval_jev_v81_boundary.ps1`.

Stage 0 passes only if both protected-promo windows score below 0.85 and both
paid-ad windows score at or above 0.85. This result proves only that the revised
policy separates the known failure boundary without immediately losing the two
weakest paid-ad signals. It does not establish episode-level recall or
generalization. If it passes, proceed unchanged to Stage 1. If it fails, stop
V8.1 and design a new experiment rather than tuning on these four windows.

### Stage 0 result

Stage 0 passed 4/4 cases on October 4, 2026. The protected Dr. Death promo
windows moved from 0.80 to 0.35 and from 0.77 to 0.29. The two marginal paid-ad
windows moved from 0.86 to 0.91 for This American Life and from 0.89 to 0.92 for
Armchair Expert. The run cost $0.00046533; median latency was 196.1 ms and
maximum latency was 253.5 ms.

This supports the narrow separation hypothesis on the known boundary cases. It
does not change the frozen V8 rejection or establish production readiness.
Proceed to Stage 1 without changing the prompt, threshold, window geometry, or
protected-promo policy.

## Stage 1: locked regression validation

Run the unchanged V8.1 protocol across these six existing approved episodes:

- Bill Simmons / Kawhi — paid-only, long conversational and inserted ads;
- Economics of Everyday Things — paid-only;
- Darknet Diaries — paid ads plus membership material;
- 99% Invisible (`99-percent-invisible`) — paid ads plus network promos;
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

The Stage 1 runner uses the frozen V8.1 prompt and 0.85 threshold, writes only
to `tmp/ad-eval/jev-chunk-scout-v8.1/`, and has a $0.060 hard spend cap. Its
dry run must print the exact request count, largest estimated request, and
projected cost before any live request is allowed.

### Stage 1 result

Stage 1 ran on October 4, 2026. The initial report was formally rejected under
its frozen gates: it hit all 30 approved paid-ad spans, covered 100% of the
1,136.74 approved paid-ad seconds, had zero positives in the AI News Strategy
Daily no-ad control, and marked only 16.4% of all listening time positive. It
failed exactly one gate: two of 11 promo-only windows were positive.

Those windows were `unexplainable-w0012` (0.89) and `unexplainable-w0013`
(0.91). Both overlap the currently approved `network_promo` span from 740.34s
to 803.28s, which includes the separate sentence, “This series is presented by
Comcast Business.” That golden span's own note says to verify whether the Comcast
line should be separate paid advertising. V8.1 explicitly defines a distinct
third-party sponsor or underwriting message as positive, so this is a label-policy
mismatch in the golden—not evidence to tune the model, prompt, or threshold.

The sponsor sentence was human-adjudicated as paid advertising and split into a
2.34-second `paid_ad` golden span (742.12-744.46s), retaining the surrounding
material as `network_promo`. The original request and response records and
initial rejected report remain unchanged. A separate no-network rescore against
the corrected golden passed every gate: all 31 paid spans and 1,139.08 paid
seconds were covered; all nine promo-only windows and the no-ad control were
negative; and positive coverage remained 16.4%. The rescore is recorded in
`tmp/ad-eval/jev-chunk-scout-v8.1/report-rescored-after-golden-adjudication.json`.

Stage 1 is therefore passed. Proceed to the fresh Stage 2 holdout without
altering the V8.1 model policy, prompt, threshold, or window geometry.

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

### Stage 2 intake

On October 4, 2026, the following recordings were pinned for the holdout. The
three new episodes now have human-approved goldens; the three reused goldens
were selected because they have no prior Jev response artifact. The expected
format is a collection target, not a label claim; human review may replace any
candidate that does not fit its slot.

| Intended slot | Slug | Pinned episode |
| --- | --- | --- |
| conversational host reads | `dan-le-batard-local-hour` | *Local Hour* approved golden: five host reads and four DAI spots; no prior Jev response artifact |
| DAI/commercial delivery | `smartless-olivia-wilde` | *SmartLess: Olivia Wilde* approved golden: nine DAI spots and one host read; no prior Jev response artifact |
| public-radio underwriting | `stage2-this-american-life` | *898: An Argument* (`46226 at https://www.thisamericanlife.org`) |
| sports/baked delivery | `cougar-sports-2026-07-17-hour4` | *7-17-26 - Hour 4 - How will the new 5 and 5 rule affect college football recruiting and BYU football?* (`https://api.spreaker.com/episode/73039979`) |
| no paid ad/no promo control | `stage2-ai-news` | *How AI agents are changing the way you buy software* (`6ac1d9f78da1db2e6f50fe12`) |
| no-paid-ad promo control | `stage2-dr-death` | *Listen Now: My Mom’s Murder* (`gid://art19-episode-locator/V0/rvZqv_NlG9y1nJum7Ki293LkkvS2rpgDLu1sDrQBqDg`) |

The three new candidate audio files are downloaded under `tmp/ad-eval/`; the
three reused approved goldens have no prior Jev response artifact. Together they
already supply 30 paid-ad spans before review of the new public-radio episode.
The set has 38 approved paid spans and both requested controls. Its transcripts,
goldens, request payloads, and 0.85 threshold are frozen before the first paid
request. The next step is to run V8.1 unchanged.

Run the exact Stage 1 V8.1 requests and threshold without alteration. Apply the
same gates, plus zero positive windows in both no-paid-ad controls. Any failure
rejects V8.1 for production scouting; do not tune on the holdout.

Passing both stages establishes only that the two-minute scout is viable. The
next experiment must separately validate localization of exact typed spans
before V8 can affect listener playback or replace Gemini.

### Stage 2 result

The frozen Stage 2 holdout passed on October 4, 2026. The complete immutable
inputs and responses are in `tmp/ad-eval/jev-chunk-scout-v8.1-stage2/`.

- 281 overlapping two-minute windows across six held-out episodes;
- all 38 of 38 approved paid spans were hit, with 100% paid-second coverage;
- the genuinely ad-free episode had zero positive windows;
- the all-promo feed-drop had zero positive windows across all six protected
  promo-only windows; and
- positive coverage was 22.47% of listening time, below the 40% ceiling.

Actual cost was $0.03690 (below the $0.06 cap), with 187.5 ms median request
latency. No policy, prompt, window geometry, or threshold was changed after
the inputs were frozen.

## V8.2A: 15-second refinement smoke test

This is intentionally a small mechanism test, not a second large evaluation.
The input is a two-minute window that V8.1 already marked positive. Within that
window, ask the unchanged paid-ad question on overlapping 15-second slices with
a 10-second stride. A positive slice is a candidate ad region; adjacent positive
slices are merged only for scoring.

Use four development paid-ad windows and one protected promo-only sentinel:

| Class | Frozen parent window | Why it is included |
| --- | --- | --- |
| paid | `economics-of-everyday-things-w0010` (540-660s) | a short DAI near the window end |
| paid | `99-percent-invisible-w0028` (1620-1740s) | two adjacent inserted ads |
| paid | `bill-simmons-kawhi-w0050` (2940-3060s) | a short trailing ad fragment |
| paid | `darknet-diaries-w0035` (2040-2160s) | a conversational host read |
| protected promo | `darknet-diaries-w0069` (4080-4186.65s) | a membership promo with no paid span |

This makes 60 short requests at most. Freeze the existing V8.1 paid-ad
wording, model, and 0.85 threshold. Do not use Stage 2 holdout episodes to
select or tune this smoke test.

The smoke test passes only if every clipped approved paid span overlaps a
positive slice, at least 99% of its clipped paid seconds are covered, every
promo-only slice is negative, and the union of positive slices covers no more
than half of the four paid parent windows (240 seconds). Cap spend at $0.01.

Passing shows that the scout can be narrowed to a roughly 15-second candidate
region. It does **not** establish exact playback boundaries; a separate
held-out localization evaluation must still measure start/end error before any
production decision.

### V8.2A result

V8.2A was rejected on October 4, 2026. It made 59 requests for $0.00296.
All five clipped paid spans overlapped a positive refinement slice, the
promo-only sentinel had zero positive slices, and refinement reduced candidate
coverage from 480 seconds to 160 seconds (33.3%). However, only 88.90% of
clipped paid seconds were covered, below the precommitted 99% gate.

The only miss was the trailing portion of the second adjacent ad in
`99-percent-invisible-w0028`: the refiner marked 1710-1725 seconds positive,
but the approved ad continued through the parent window's end at 1740 seconds.
Do not lower the threshold or change the grid from this result. The next design
must handle an ad that crosses a scout-parent boundary—for example, evaluate
the union of refinement slices across every overlapping positive scout window—
before testing any new threshold or playback behavior.

## V8.2B: boundary-stitching decision test

Strategy 8 remains a coarse-to-fine pipeline:

1. V8.1 finds broad regions that may contain paid ads. This stage is validated.
2. A refiner narrows those regions without losing paid seconds. This stage is
   promising but not yet validated.
3. Only after refinement passes may a final sentence-boundary step produce
   playback spans.

V8.2A evaluated each overlapping two-minute parent independently, which is not
how the complete pipeline should behave. V8.2B tests the smallest correction:
treat adjacent positive scout windows as one continuous candidate region,
deduplicate identical 15-second slices, and join two positive refinement runs
when they are separated by no more than one 15-second slice. Keep the model,
prompt, 0.85 threshold, 15-second slice, and 10-second stride unchanged.

Reuse all 59 frozen V8.2A responses, including the original slices through the
end of `99-percent-invisible-w0028`. Add only the six previously unevaluated
slices between 1740 and 1800 seconds. Do not rebuild or repurchase the earlier
overlap from `w0029`: its target times repeat existing slices but its surrounding
context changes at the parent boundary, so its requests are not byte-identical.
Stitch the saved and new results by their time boundaries, then score the union
of `w0028` and `w0029` rather than requiring each parent to cover its own clipped
ad independently.

V8.2B passes only if:

- every approved paid span in the five development cases is hit;
- at least 99% of approved paid seconds are covered after the frozen bridge
  rule;
- the membership-promo sentinel still has zero positive slices; and
- refined positive coverage remains at or below 50% of the merged eligible
  scout regions.

This is a development decision test, not new production evidence. If it passes,
freeze the complete scout, refinement, deduplication, and bridge rules and run
a small held-out localization evaluation on two episodes. If it fails, abandon
the 15-second grid refiner while retaining the validated V8.1 scout, and test a
sentence-level anchor-and-bridge localizer using the existing V7.1 evidence.

### V8.2B result

V8.2B passed on October 4, 2026. It reused all 59 frozen V8.2A responses and
made exactly six new requests for $0.00030758. All six new slices scored between
0.93 and 0.95. After applying the frozen 15-second bridge rule, all six approved
paid spans were hit and 100% of their 194.95 seconds were covered. The promo-only
sentinel retained zero positive slices. Refined positive coverage was 235 of 540
eligible seconds (43.52%), below the precommitted 50% ceiling.

This result validates the boundary-stitching mechanism on the development
cases. It does not yet validate localization on unseen episodes or playback
boundaries.

## V8.3: two-episode held-out localization test

Freeze the complete V8.2B behavior before observing any V8.3 response:

- use the saved V8.1 Stage 2 scout decisions at the 0.85 threshold;
- merge adjacent or overlapping positive 120-second scout windows into candidate
  regions;
- evaluate each merged region on a deduplicated 15-second grid with a 10-second
  stride and the unchanged paid-ad-presence prompt and 0.85 threshold; and
- merge positive slices and bridge gaps of no more than 15 seconds.

Use exactly two Stage 2 episodes that were not used to design V8.2:

- `stage2-this-american-life`: eight paid DAI spans plus a protected membership
  appeal; and
- `cougar-sports-2026-07-17-hour4`: eleven paid DAI/host-read spans plus a
  protected network promo.

These two episodes provide 19 approved paid spans across DAI, host-read, and
public-radio delivery, plus both protected promo types. Pin the existing scout
report, transcript hashes, golden hashes, request hashes, model, price card, and
all geometry before the live run. Do not change a threshold or label after
responses are observed.

V8.3 passes only if:

- all 19 approved paid spans overlap stitched positive refinement coverage;
- at least 99% of approved paid seconds are covered;
- every refinement slice that overlaps protected material but no paid span is
  negative; and
- stitched positive coverage is at most 50% of the merged scout-candidate time.

This remains a localization validation, not production playback validation.
If V8.3 passes, next test snapping stitched regions to transcript sentence
boundaries on a small manually inspected set. If it fails, retain the validated
V8.1 scout but reject the 15-second grid refiner and move to sentence-level
anchor-and-bridge using V7.1 evidence.

### V8.3 result

V8.3 was rejected on October 4, 2026. It made 195 requests across eight merged
scout regions in two held-out Stage 2 episodes for $0.01023650. It hit all 19
approved paid spans, kept all 10 protected-only refinement slices negative, and
kept candidate coverage at 32.89% (642.04 of 1,952.04 seconds). It failed the
precommitted paid-second gate: 405.94 of 460.72 paid seconds were covered
(88.11%), below 99%.

Nearly all of the loss came from one 61.18-second Shopify testimonial in
`cougar-sports-2026-07-17-hour4`. The refiner covered only its first 7.40
seconds. The approved span contains a 29.10-second stretch with no transcript
sentence coverage, which no transcript-only method can localize. In the
remaining spoken testimonial material, the refiner returned 0.68-0.80, below
the frozen 0.85 threshold. A separate 1-second trailing boundary miss accounts
for the rest of the loss.

Do not lower the threshold, enlarge the bridge rule, or reinterpret this result:
all would tune on the held-out evidence. V8.3 rejects the 15-second grid
refiner as the next production localizer. Retain V8.1's validated two-minute
scout. The next minimal investigation is sentence-level anchor-and-bridge:
within scout-positive regions, find high-confidence paid-ad anchor sentences,
then use adjacent sentence continuity to bridge only across ordinary transcript
gaps. It must separately report untranscribed audio gaps as `unknown`, rather
than claiming a transcript-derived playback boundary through them.

## V8.4: coherent-block rescue smoke test

Before building an automatic sentence-anchor localizer, test its core premise
with exactly three frozen blocks from the V8.3 failure episode. Use the unchanged
V7.1 complete-block tier question and model:

- sentences 10-17, 27.60-88.78s: the missed Shopify testimonial, including the
  29.10-second interval with no transcript sentence; expected `skip_obvious`;
- sentences 18-22, 89.22-113.40s: the station/show promo immediately after it;
  expected `skip_more_only`; and
- sentences 30-39, 141.80-189.32s: the clear Atrium sponsor read; expected
  `skip_obvious`.

This is a development mechanism test. It does not discover its own anchors and
cannot validate production localization. It passes only if all three blocks
receive their expected tier, using one request per block and a $0.005 spend cap.
If it passes, the next experiment may build automatic high-confidence anchors
and continuity expansion. If Shopify is not `skip_obvious`, stop pursuing the
V7.1 block classifier for Strategy 8 localization.

### V8.4 result

V8.4 was formally rejected on October 4, 2026. The three requests cost
$0.00027435. The Shopify testimonial and Atrium sponsor were both classified
as `skip_obvious`, so coherent-block context did recover the specific paid ad
that the 15-second refiner missed. The station/show promo was conservatively
classified `keep_protected` rather than the expected `skip_more_only`.

The Shopify rescue was not a robust anchor: `skip_obvious` received probability
0.47 versus 0.42 for `mixed_split`, and the selected answer's confidence was
only 0.35. Atrium was substantially clearer at 0.77 and 0.70 confidence. This
means the known failure can be rescued when its correct block is supplied, but
the evidence is too ambiguous to justify building an automatic production
localizer around this classifier.

Stop Strategy 8 localization experiments here. Retain V8.1 as a validated
two-minute paid-ad presence scout, but do not use V8.2-V8.4 to create playback
skip spans. Any future localization proposal must introduce a materially new
signal—such as audio boundaries or a model designed to emit boundaries—and a
new independently frozen holdout. Repeating these prompts, relaxing gates, or
tuning confidence thresholds on the observed episodes would be overfitting.
