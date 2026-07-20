# Ad detection approaches (on-device)

Catalog of candidate ways to mark **ad vs content** from a podcast episode, down to the word, **without cloud calls at runtime**.

**Status (2026-07):** `topic-llm-v1` (Apple Foundation Models) is **scrapped** for production use — weak on Cougar DAI cold opens and TAL midrolls (swiss-cheese FNs, midroll FPs, 4k context, guardrail refusals). Ship default remains **heuristic-cue-v6.1** until a path below proves out on `tmp/ad-eval/*/REVIEW.html`.

**Eval notes:** Prefer human-approved goldens under `tmp/ad-eval/`. TAL’s large golden set is partly polluted (story spans marked “ad” via ad-free transcript diff) — clean before trusting scores.

---

## Problem

Input: timed transcript (`[TimedWord]`), optional show/episode metadata, optional audio.  
Output: ad pods `[start, end]` aligned to word boundaries, suitable for skip/mute.

Constraints:

- Runtime must stay **on device** (no cloud LLM/API for labeling).
- Must handle both **DAI fills** (cold opens / midrolls that change per download) and **baked-in** ads (host live-reads, underwriting identical in every copy).

## Labeling policy: feed-drops and cross-posts

A full feed-drop / cross-post should be treated as **episode content**, not as a
network promo, even if the source show is different from the subscribed show.

Examples:

- A Dr. Death RSS item titled "What To Listen To Next" that plays a substantial
  episode/preview of Dan Taberski's Manifesto is content for this feed item.
- A publisher intentionally running episode one of another show as the main
  payload is content.

Do still label separately inserted ads, membership CTAs, or short network promos
that wrap or interrupt the feed-drop. The distinction is:

- **Short trailer/promo inside a normal episode** → `network_promo`
- **Whole/substantial cross-post episode as the payload** → content / no span
- **Separate paid ad inside the cross-post** → paid ad span
- **Brief host framing that explains the cross-post** → content unless it turns
  into a standalone CTA unrelated to the feed-drop payload

This prevents the detector from learning the bad rule "other podcast title =
ad," which would create large false positives.

---

## Approach summary

| # | Approach | Core idea | Wins | Loses |
|---|----------|-----------|------|-------|
| 1 | Double-fetch DAI diff | Re-download same episode; audio/transcript diverge on fills → those runs are ads | Word-exact on DAI; no ML; kills Cougar-style cold opens | Baked-in / host live-reads identical in both copies; 2× download (+ ASR) |
| 2 | Distilled Core ML tagger | Cloud LLM labels offline → fine-tune small BIO tagger → ship Core ML | Fast, no guardrails, word-level | Training corpus + pipeline cost |
| 3 | Anchor + Viterbi cue-HMM | Sentence classes (clear-ad/content, enter/CTA/resume anchors); logistic emissions; Viterbi + duration prior; fill between anchors | Fixes greedy bleed; fits Darknet “sponsored by → body → URL → resume” | Cold opens with no enter anchor; ASR-mangled CTAs need soft exit |
| 4 | Embedding outlier + repetition memory | Off-centroid sentences + local cross-episode fingerprint repeats | Unsupervised; precision grows with listening | Weak on in-domain live-reads |
| 5 | Audio-domain | Host enroll + music bed + splice/loudness | Topic-agnostic announcer ads | Misses host-read; DSP heavy |

**User idea (sentence confidence + neighbors):** score each sentence vs neighbors and the episode; treat enter / CTA / “welcome back” as transitions; fill interiors between anchors. Correct mental model for baked-in stacks. Informal neighbor if/else recreates heuristic bleed — **fold into #3** (anchors as transition evidence, global Viterbi decode, not greedy rules).

**Recommended stack (when we resume after Phase 1):** **#1** for DAI fills → **#3** for baked-in residue → optional **#4** repetition. Near-term work: [ad-detection-dai-phase1.md](ad-detection-dai-phase1.md) (probe only).

---

## 1. Double-fetch DAI differential

**Idea:** Dynamic ad insertion stitches different ads (or lengths) into each HTTP fetch of the “same” episode. Download twice → compare. Regions that differ are ads; regions that match are content.

**Pipeline (offline prototype, then app):**

1. Fetch `audio.mp3` and later `audio2.mp3` from the same `audioUrl`.
2. Cheap probe: size, SHA-256, decoded duration — if they differ, DAI is likely.
3. Transcribe both → align word sequences (Myers / `difflib`).
4. Divergent runs on copy A → ad spans from A’s timestamps; merge short gaps; drop pods &lt; ~5s.

**Pros:** Word-exact boundaries by construction; no model; directly targets the failures topic-llm missed (Cougar cold-open stacks, TAL midroll fills).

**Cons:** Host-read / baked-in ads appear in both copies → FN by design. Cost: 2× download and usually 2× ASR. Some CDNs may serve the same fill for a while (identical pair ≠ “no DAI” forever).

**Next step:** Phase 1 probe only — see [ad-detection-dai-phase1.md](ad-detection-dai-phase1.md).

---

## 2. Distilled Core ML token classifier

**Idea:** Use a frontier cloud LLM **only at development time** to label many transcripts word- or sentence-level. Fine-tune a small encoder (DistilBERT / MobileBERT class), quantize, ship as Core ML. Runtime: whole episode tagged in seconds, BIO spans → word edges.

**Pros:** Strong ceiling; no on-device LLM context/guardrail issues; true word-level tags.

**Cons:** Building and maintaining a training set; MLOps; model size/latency budgeting on phone.

**When:** After #1/#3 show residual hard cases that need a learned “ad register.”

---

## 3. Anchor + Viterbi cue-HMM (sentence rating, done right)

**Idea:** Rate sentences with a small set of classes / features, then find the globally best ad/content segmentation.

**Sentence signals (examples):**

- **Enter anchors:** “This episode is sponsored by…”, “Support for X comes from…”, “This message comes from…”
- **CTA anchors:** URL / “visit … .com”, “book a demo”, “apply today”
- **Resume anchors:** “It’s American life. Act One.”, “For this episode, I sat down…”, “welcome back”
- **Clear ad / clear content:** marketing register vs in-domain story
- **Episode outlier:** off-topic vs show domain (optional)

**Decode:** logistic (or hand-init then fit) emission scores → 2-state HMM (ad/content) with duration prior (~15–90s pods, allow ad→ad for stacked spots) → **Viterbi**. Interiors between enter and CTA get filled as ad without classifying every mid-sentence in isolation.

**Why not greedy neighbors:** heuristic-cue-v6.1 and informal “look at prev/next” both bleed at exits. Viterbi is the principled version of the user’s bracket-and-fill intuition.

**Pros:** Tiny, deterministic, unit-testable; matches Darknet Threadlocker→Mays→resume patterns; good for baked-in underwriting.

**Cons:** DAI cold opens often have **no enter sentence** (episode starts mid-pitch) — need #1 or strong start/outlier cues. ASR may mangle URLs (“eight for him” / spaced `.com`) — soft exit + duration prior required.

**Corpus note:** Exit/CTA cues are near-universal on real ads; enter cues are common on baked-in underwriting, rarer on DAI cold opens.

---

## 4. Embedding outlier + cross-episode repetition memory

**Idea:**

1. Sentence embeddings on-device (`NLContextualEmbedding` or bundled MiniLM).
2. **Outlier:** ads often sit far from the episode centroid (mattress vs sports talk).
3. **Repetition:** fingerprints of windows that near-duplicate windows from *other* episodes/shows are almost certainly ads (DAI creatives repeat; story does not). Local library grows as the user listens.

**Pros:** Unsupervised; repetition has very high precision over time.

**Cons:** In-domain live-reads (local hotel sponsor) are not outliers and may not repeat; boundaries are sentence-level without refinement.

**Best as:** precision booster layered on #1/#3, not a standalone ship path.

---

## 5. Audio-domain detection

**Idea:** Ads are often produced separately — different voice, music bed, loudness/EQ, hard splices. Enroll host voice across episodes; detect speaker change, music/voice (SoundAnalysis), splice/loudness discontinuities; map to word timestamps.

**Pros:** Topic-agnostic; catches announcer reads even when copy is “on brand.”

**Cons:** Misses host-read live-reads; real DSP work; best as boundary sharpening, not sole detector.

---

## Scrapped path (do not revive without new evidence)

### topic-llm-v1 (Apple Intelligence Foundation Models)

TopicCard + ~20s windows + on-device labels (`ad`/`content`/`mixed`/`unsure`) + merge.

**Why it failed in practice:**

- ~4k on-device context → batch/session blowups, silent fail-safes to content
- Guardrail **refusals** on casino/loan-style copy (common DAI)
- REVIEW on Cougar/TAL: incomplete cold opens, midroll FN/FP, show-resume bleed

Code may remain for experiments; it is not the product path.

### Heuristic-only ceiling

`heuristic-cue-v6.1` remains the fallback. Useful for classic underwriting phrases; weak on DAI cold opens without openers and on local live-reads. Treat as baseline, not the end state.

---

## Decision log

| Date | Decision |
|------|----------|
| 2026-07 | Scrap topic-llm as ship path after Cougar/TAL REVIEW |
| 2026-07 | Catalog approaches #1–#5; merge sentence/neighbor idea into #3 |
| 2026-07 | Next concrete work: **DAI Phase 1 probe only** (no word-diff yet) |

---

## Related

- [ad-detection-dai-phase1.md](ad-detection-dai-phase1.md) — Phase 1 probe spec (write/run when executing that plan)
- [matching-spec.md](matching-spec.md) — word matching / intervals
- Offline corpus: `tmp/ad-eval/` (gitignored), scripts `scripts/ad_eval_*.py`
