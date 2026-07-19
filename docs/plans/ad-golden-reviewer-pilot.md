# Ad golden reviewer — Cougar Sports pilot

**Status:** approved for implementation

**Pilot:** Cougar Sports only

**Purpose:** produce one trustworthy, human-approved podcast ad golden while proving a fast review workflow before touching the other 12 episodes.

## Boundaries

- Do not modify the factory, PodWash player, or production ad-detection algorithms.
- Preserve all 13 downloaded `audio.mp3` and `meta.json` inputs.
- Clean and regenerate only Cougar Sports during the pilot.
- Do not prepare the other 12 episodes until the Cougar workflow is accepted.
- Label advertisements and promotional material only; general tangents or other non-story material are out of scope.
- The human reviewer never edits Markdown or JSON and never exports files manually.

## Pilot data preparation

1. Remove the unused local `qwen3-coder:30b` model to recover disk space while retaining `gpt-oss:20b`.
2. Hash the Cougar audio and metadata, then remove its obsolete transcripts, proposed goldens, detector results, metrics, Markdown exercises, and generated review pages.
3. Generate a fresh word-timed transcript with Whisper `large-v3` through MLX.
4. Write only:
   - `transcript.json`
   - `transcript_source.json` with engine/model revision, audio hash, transcript hash, duration, word count, and generation date
5. Validate non-empty output, monotonic word times, valid word ranges, and coverage through the actual audio duration.

## AI proposal pipeline

Number every transcript word with a stable zero-based index.

Run two independent development-time labeling passes:

- Codex as the primary reasoner.
- Local `gpt-oss:20b` with high reasoning effort and deterministic output.

Each pass uses roughly 2,000-word windows with 200-word overlap and returns exact word boundaries, label, optional advertiser, boundary quotes, confidence, and rationale. Focused follow-up passes refine every candidate boundary.

A final reconciler produces one visible proposal set by:

- deduplicating overlap-window results;
- separating back-to-back creatives;
- checking cold opens, episode endings, URLs, promo codes, sponsorship language, and disclaimers;
- protecting editorial re-entry;
- retaining hidden per-model support and disagreement metadata for the final missed-ad audit.

The reviewer shows one proposal overlay, never competing model overlays.

## Reviewer application

Build a standalone localhost application under `Tools/AdGoldenReviewer`, launched by one script and bound only to `127.0.0.1`.

### Transcript experience

- Dark mode with high-contrast typography.
- Entire episode in one continuous scrolling transcript.
- Readable visual paragraphs that do not constrain annotation boundaries.
- Fixed right-side controls.
- No visible timestamps and no audio controls.
- Plain text is content.
- AI proposals are translucent/patterned; human edits are solid.
- Color and an inline label chip identify every marked span.

Quick labels:

1. Paid DAI / inserted ad — yellow
2. Paid baked-in ad — orange
3. Paid host-read sponsor — purple
4. Network / cross-promo — blue
5. Membership / fundraising CTA — green
6. Content — erase annotation

### Editing

- Drag across complete words to create a selection.
- Apply a label from a floating palette or the fixed panel.
- Click a span to activate it.
- Drag start/end handles that snap to words.
- Relabel or delete in one action.
- Painting over an existing annotation splits or truncates it safely.
- Provide explicit split and merge tools.
- Preserve adjacent creatives as separate spans, even when their labels match.
- Prevent overlapping final spans.
- Support undo/redo and keyboard shortcuts.
- Update only affected word elements while dragging; never rerender the full transcript on pointer movement.

### Review completion

- Save an explicit `reviewedThroughWord` cursor and resume location.
- Autosave every edit and cursor change directly to disk.
- Untouched AI proposals are accepted by the final episode approval; they do not require individual clicks.
- Before approval, require a disagreement queue covering:
  - unmarked regions flagged by either model;
  - strong commercial cues outside marked spans;
  - suspicious cold-open/end regions;
  - materially different proposed boundaries.
- Provide a temporary hide-highlights mode while inspecting disagreement items.
- Final approval requires the review cursor at the final word, completed disagreement queue, valid non-overlapping labels, matching transcript/proposal hashes, and an end-to-end review attestation.
- Every word outside the approved spans is content by definition.

## Persistence and golden schema

The local API provides:

- `GET /api/episodes`
- `GET /api/episodes/{slug}`
- `PUT /api/episodes/{slug}/review`
- `POST /api/episodes/{slug}/approve`

Use atomic writes and revision numbers so multiple browser tabs cannot silently overwrite each other. Browser local storage is not canonical.

Working files remain under `tmp/ad-eval/cougar-sports/`:

- `audio.mp3`
- `meta.json`
- `transcript.json`
- `transcript_source.json`
- `proposal.json`
- `review.json`

The approved compact golden is written outside disposable `tmp` data:

`eval/ad-detection/goldens/cougar-sports.json`

It stores the schema/policy version, episode/audio/transcript hashes, ASR provenance, reviewer and approval date, completed review cursor, end-exclusive word indices, derived timestamps, normalized ad metadata, optional advertiser, and proposal/human provenance. It contains no full transcript text.

Canonical truth is one span per creative. Ad-pod grouping may be derived without absorbing intervening content words.

## Verification and human handoff

Before handoff:

- test interval create/resize/relabel/delete/split/merge operations;
- test atomic autosave, reload/resume, revision conflicts, stale transcript hashes, and approval validation;
- exercise the full Cougar transcript for responsive selection and handle dragging;
- verify dark mode, fixed controls, hidden timestamps/audio, and keyboard behavior in the in-app browser;
- confirm no factory, player, or production detector files changed.

The human starting point is the first word of Cougar Sports in the localhost reviewer. The reviewer reads once, corrects colored spans, advances the review cursor, resolves the short disagreement queue, and approves.

After approval, compare the frozen Codex-only, `gpt-oss`-only, and reconciled proposals against the final golden. Use review time, added/deleted/relabelled spans, boundary edits, proposal precision/recall, and disagreement yield to improve the workflow before processing another episode.
