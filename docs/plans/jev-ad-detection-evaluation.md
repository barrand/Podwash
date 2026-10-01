# Jev Ad-Detection Evaluation

Status: **proposed; do not replace Gemini in production yet**.

This is the canonical plan for deciding whether TypeSafe AI's Jev System One
model should replace PodWash's Gemini-based cloud ad detector. It records a
listener-safety-first recommendation: run an offline shadow pilot against the
existing human-approved corpus before any provider or consent change ships.

## Decision summary

Jev is a good technical candidate but not yet a safe production replacement.
It accepts text state and returns typed decisions/probabilities, which matches
PodWash's existing timed-sentence input and removes Gemini's generated-JSON
failure mode. Its publicly advertised price is $0.042 per million input tokens
with free output, versus Gemini 3.6 Flash's currently listed $0.75 input / $3.75
output per million tokens through December 2026.

The unresolved issue is listener harm at boundaries. The available
podcast-specific public evaluation reports very low latency and cost for Jev,
but also materially more editorial speech removed than its best comparator when
it classified coarse VAD segments. PodWash must not generalize that result to
its sentence-level implementation without reproducing it on its own goldens.

Authoritative external references, checked October 1, 2026:

- [TypeSafe API introduction](https://docs.typesafe.ai/)
- [TypeSafe confidence semantics](https://docs.typesafe.ai/confidence)
- [TypeSafe Jev announcement, early-access status, and price](https://typesafe.ai/blog/introducing-system-one-models-and-jev)
- [Gemini Developer API pricing](https://ai.google.dev/gemini-api/docs/pricing?hl=en)
- [Independent podcast-specific Jev evaluation](https://github.com/ttlequals0/MinusPodJev/blob/main/JEV_BENCHMARK_REPORT.md)

## Product and safety contract

1. The primary failure is removing spoken editorial content, not leaving an ad
   unskipped. Cost savings and incremental recall never justify increased
   listener harm.
2. Gemini remains the sole listener-facing provider until Jev passes every
   promotion gate below.
3. The first pilot uses only the tracked, human-approved local corpus. It sends
   no listener transcript to TypeSafe and changes no app behavior or consent.
4. A later live shadow test is a separate decision. It requires TypeSafe in the
   privacy disclosure, a new/revised consent version, data-retention and
   security review, a billing cap, and explicit approval.

## Technical design for the offline pilot

### Provider seam

Introduce a backend-only `AdDecisionProvider` abstraction with a common input
of ordered timed sentences and a common output of normalized PodWash ad spans.
Keep the existing Gemini implementation behind that seam. Add a Jev
implementation that is enabled only by the evaluator/explicit server-side
experiment setting.

The provider identity, model revision, question-template revision, assembly
revision, and transcript fingerprint must all feed cache and result-version
material. Never log transcript text; record only counts, span totals, latency,
model/version, token usage, and measured request cost.

### Jev request and span assembly

Use a `Choice` question per sentence with the mutually exclusive options
`advertisement`, `editorial`, and `uncertain`. The state is the ordered
timed-sentence transcript; each atomic question identifies one sentence and
asks whether it is paid advertising, including host-read and ad-network
promotion but excluding show content, credits, and ordinary discussion.

Use the returned advertisement probability and choice confidence to assemble
only contiguous, high-certainty ad sentence runs. Preserve exact sentence
timestamps; do not adopt VAD-size segments or inferred word cuts. Treat
`uncertain`, low confidence, and unavailable/invalid responses as editorial
for automatic skipping. Overlap chunks only when transcript limits require it,
then de-duplicate by sentence ID before span normalization.

The development set may tune the entry threshold, stay threshold, minimum
duration, overlap, and merge gap. Freeze these parameters before running the
holdout. Do not tune on failures discovered in the holdout.

## Evaluation protocol and promotion gates

1. Create a deterministic corpus split from the 21 human-approved `ads-only-v1`
   goldens. Keep no-ad controls and a representative mix of host reads,
   dynamically inserted ads, promos, and short ads in the frozen holdout.
2. Replay the same transcripts through current Gemini and Jev. Measure
   time-weighted ad precision/recall, ad time retained per hour, editorial time
   removed per hour, median/p95 boundary error, false spans on no-ad controls,
   largest accidental cut, p50/p95 end-to-end latency, input/output tokens, and
   billed cost per episode.
3. Save a reproducible report, provider response metadata with transcript text
   redacted, normalized spans, metric tables, and reviewer packets for every
   provider disagreement.
4. Manually inspect every disagreement around openings, closings, host reads,
   self-promotion, ad-network inserts, repeated advertisements, and show
   resumption.

Jev is eligible for production only if, on the frozen holdout, it:

- is non-inferior to Gemini on ad recall;
- adds no false span on no-ad controls;
- removes no more than one additional second of editorial content per hour;
- introduces no new accidental removal longer than 30 seconds; and
- has a measured operating-cost advantage after including all requests and
  infrastructure.

Failure of any gate means retain Gemini. The evaluation report may still
identify narrower uses for Jev, such as a conservative first-pass candidate
filter or disagreement reviewer, but that requires a separate plan.

## Verification

- Unit tests: typed response parsing, invalid/missing answer handling,
  thresholding, uncertain-answer suppression, chunk overlap/de-duplication,
  contiguous span assembly, cache-key/version invalidation, and fallback.
- Corpus tests: deterministic split, golden integrity, no-ad controls,
  repeatable scoring, and no accidental reuse of development examples in
  holdout reporting.
- Regression checks: Gemini results remain unchanged when the Jev experiment is
  disabled; no transcript body is emitted in logs, telemetry, cache metadata,
  or failure artifacts.
- Operations checks: request caps, failure-rate/latency dashboards, and a
  provider kill switch before any live shadow experiment.

## Non-goals

- Do not replace local ASR, upload audio, or expose a listener setting during
  the offline pilot.
- Do not use unofficial Jev-compatible endpoints; evaluate the official
  TypeSafe endpoint and an explicitly pinned model revision.
- Do not use Jev's public confidence claim as proof of calibration for podcast
  ads. Its thresholds must be selected and validated on PodWash's corpus.
