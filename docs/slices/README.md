# PodWash slice stories

This folder holds **slice stories** — the working documents agents use to build PodWash one vertical slice at a time. The high-level product vision stays in [`product-requirements.md`](../product-requirements.md). The normative matching algorithm lives in [`../specs/matching-spec.md`](../specs/matching-spec.md). Process, roles, and gates live in [`multitask-workflow.md`](../multitask-workflow.md). Foundational technical decisions are pinned in [`../adr/000-foundations.md`](../adr/000-foundations.md).

If you have never worked this way before, read this page once, skim [`_template.md`](_template.md), then open [`slice-01-foundation.md`](slice-01-foundation.md) as your first example.

**New agent / fresh chat:** start with [`dark-factory.md`](../dark-factory.md) — how the factory, scripts, and coordinator sessions work.

## Source of truth model

| Document | Answers | Changes |
|----------|---------|---------|
| **[`product-requirements.md`](../product-requirements.md)** | **WHAT/WHY** — vision, features, constraints, legal, monetization, non-goals | Rarely (strategy shifts) |
| **[`../specs/matching-spec.md`](../specs/matching-spec.md)** | **Exact algorithm behavior** — constants, normalization, merge semantics, golden examples | Only via a superseding spec change |
| **`docs/slices/slice-NN-*.md`** | **HOW/WHEN** — crux, acceptance criteria, verification, status for one increment | Every active slice session |

**Conflict rule:**

- **PRD wins** on product intent; **spec wins** on algorithm behavior.
- **Slice wins** on implementation scope for *that increment*.
- If a slice contradicts the PRD or spec, **stop** — update the upstream doc first, then the slice.

**Detail placement:** Slice files **reference** PRD/spec sections and add only slice-specific, testable deltas — not duplicate paragraphs.

## Slice index (kanban order)

The dependency graph and parallel groups live in [`multitask-workflow.md`](../multitask-workflow.md#kanban-dependency-order). Current slices:

> **Next slice selection:** run [`scripts/next-slice.sh`](../../scripts/next-slice.sh) — it reads statuses + `## Depends on` here and prints the next eligible slice (or `wait`/`halt`/`done`). See [`slice-runner.md`](../slice-runner.md).

| # | File | Track |
|---|------|-------|
| 01 | `slice-01-foundation.md` | Foundation |
| 02 | `slice-02-matching-engine.md` | Core (parallel group A) |
| 03 | `slice-03-player-shell.md` | Core (parallel group A) |
| 04 | `slice-04-interval-mute.md` | Core differentiator proof |
| 05 | `slice-05-asr-spike.md` | Core (parallel group A — early: drives iOS floor) |
| 06 | `slice-06-rss-episode-list.md` | Core (parallel group A) |
| 07 | `slice-07-analysis-pipeline.md` | Pipeline |
| 08 | `slice-08-playback-integration.md` | Pipeline |
| 09 | `slice-09-analysis-ui.md` | Pipeline UI |
| 10 | `slice-10-downloads.md` | Table stakes (parallel group B) |
| 11 | `slice-11-queue-resume.md` | Table stakes (parallel group B; Core Data per ADR-007) |
| 12 | `slice-12-speed-sleep.md` | Table stakes (parallel group B) |
| 13 | `slice-13-settings.md` | Table stakes |
| 14 | `slice-14-background-audio.md` | Native polish |
| 22 | `slice-22-discovery-subscribe.md` | **MVP app shell** (before CarPlay; was "14a") — iTunes Discover + multi-subscribe |
| 23 | `slice-23-library-player-shell.md` | **MVP app shell** (before CarPlay; was "14b") — Library + production player navigation |
| 15 | `slice-15-carplay.md` | Native polish (parallel group C; **blocked until 22–23 Done**; CarPlay MVP — resolved 2026-07-10) |
| 16 | `slice-16-beep-overlay.md` | Hard deferred feature (parallel group C) |
| 17 | `slice-17-storekit.md` | Post-MVP (free at launch — deferred 2026-07-10) |
| 18 | `slice-18-segmentation-spike.md` | Differentiator 2 — MVP (spike; parallel after 07) |
| 19 | `slice-19-segmentation-integration.md` | Differentiator 2 — MVP (integration; needs 18) |
| 20 | `slice-20-analysis-timeline.md` | Pipeline UI (Skipper-style timeline; post–Slice 13) |
| 21 | `slice-21-visual-identity.md` | Native polish (brand tokens, icon, display name; needs 03 + 06) |
| 24 | `slice-24-production-analysis-wiring.md` | **MVP closure** — production `AnalysisPipeline` + bundled tiny.en for phone dogfood (needs 07, 08, 13, 23) |
| 25 | `slice-25-progressive-playback-super-seek-bar.md` | **UX** — progressive play after first ~30 s chunk; super seek bar with playhead, elapsed/remaining, frontier-clamped scrub (needs 20, 24; supersedes task-011) |
| 26 | `slice-26-episode-transcript-viewer.md` | **UX** — read cached ASR transcript (complete only); listened + skipped-ad highlights; entry from episode row + full player (needs 24, 19) |
| 27 | `slice-27-super-seek-bar-mute-markers.md` | **UX** — mute-interval markers on full-player super seek bar (distinct from yellow ads; needs 25) |

**MVP app shell (Slices 22–23):** Inserted after lock-screen polish (14) and **before CarPlay (15)**.
The factory built cleaning/playback engines but production `ContentView` was still a placeholder;
22 ships Discover + subscribe (iTunes Search API, multi-sub `PodcastStore`), 23 ships Library +
tap-to-play navigation. CarPlay and visual-identity polish depend on this shell being real.

## What goes in each slice file

Use [`_template.md`](_template.md). Beyond the classic sections (crux, deliverables, AC, mapping), every slice file has:

| Section | Rule |
|---------|------|
| **Verification commands** | Reference **`scripts/verify.sh`** — never raw `xcodebuild` with a hardcoded simulator. Filtered runs are the inner loop; **Done requires the full suite**. |
| **Verification record** | QA pastes the `VERIFY RESULT:` line (exit code, counts, `.xcresult` path) from the full-suite run. No artifact = not verified. |
| **Plan review record** | Coordinator pastes readonly ADR + test-spec review outcomes before QA test spec / Engineer. No record = next role blocked. |
| **Done gate** | Includes **"full suite green"** and the **auto-commit** (`slice-NN: <description>`) made on green. Push only when the user asks. |
| **Acceptance criteria** | Numeric thresholds where thresholds exist. Golden fixtures need documented **independent provenance** (hand-computed or spec-derived — never generated from code under test). **No XCTSkip on core ACs** — tests fail, not skip. |

## Lifecycle statuses

| Status | Meaning |
|--------|---------|
| **Draft** | Story stubbed; AC may be incomplete; mapping may be TBD |
| **Ready** | Coordinator approved: crux clear, AC automatable + numeric, gates planned |
| **In Progress** | Implement phase active |
| **Verify** | Code landed; QA running `scripts/verify.sh` |
| **Done** | Full suite green, verification record pasted, auto-commit made |

Only the Coordinator changes the `status` field (Engineers never do).

## How PM maintains slices through the pipeline

1. **Coordinator** names the active slice.
2. **PM** creates or refreshes `slice-NN-*.md`: crux, AC, out-of-scope, verification commands.
3. **Coordinator** confirms sizing checklist → status **Ready**. If the slice hits an undecided PRD §11 item, **halt and ask the user** first.
4. **Architect** (if needed) adds ADR path or design addendum; **UX** (if needed) adds spec + UI scenarios.
5. **Coordinator** runs **ADR plan review** (QA + PM, readonly); records in slice file; resolves blockers.
6. **QA** fills the verification mapping with real test names; writes the test skeleton.
7. **Coordinator** runs **test spec plan review** (Architect, readonly); records in slice file; resolves blockers.
8. **Engineer** implements → status **In Progress**.
9. **QA** runs `scripts/verify.sh` (full suite) → pastes verification record → status **Verify**, then **Done** when green with zero skips.
10. **Coordinator** makes the auto-commit `slice-NN: <description>`.

PM does not run verify or mark Done. Engineer never edits test assertions, thresholds, slice status, or goldens (see `.cursor/rules/podwash-engineer.mdc`).

## Good vs bad examples

### Crux

| Bad | Good |
|-----|------|
| "Build the player and RSS and cleaning" | "Full test suite green via scripts/verify.sh locally and in CI" |
| "Make mute sound good" | "Offline render: RMS < 0.01 full scale inside muted windows on sine fixture" |

### Acceptance criteria

| Bad | Good |
|-----|------|
| "Episode list looks polished" | "First 3 cells' labels equal the first 3 fixture titles" |
| "Volume approximately zero" | "Windowed RMS < 0.01 full scale in every 10 ms window inside intervals" |
| "Skip test when model missing" | "Test FAILS with setup instructions when model missing (no XCTSkip)" |

### Goldens

| Bad | Good |
|-----|------|
| "Generate expected_intervals.json by running IntervalBuilder" | "Transcribe spec §8's hand-computed table into expected_intervals.json; cite provenance in fixture README" |

## Related files

- [`_template.md`](_template.md) — copy-paste template for new slices
- [`../multitask-workflow.md`](../multitask-workflow.md) — kanban, roles, gates, session strategy
- [`../specs/matching-spec.md`](../specs/matching-spec.md) — normative algorithm spec + hand-computed goldens
- [`../adr/000-foundations.md`](../adr/000-foundations.md) — playback/verification/schema/floor decisions
- `.cursor/rules/podwash-*.mdc` — role rules (coordinator, pm, qa, architect, ux, engineer)
