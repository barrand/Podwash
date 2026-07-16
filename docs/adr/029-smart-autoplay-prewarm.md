# ADR-029 — Smart autoplay + analysis pre-warm

| Field | Value |
|-------|-------|
| **Status** | Accepted |
| **Date** | 2026-07-16 |
| **Supersedes** | — (carves out analysis timing from first-play-only for predicted warm slots) |
| **Builds on** | [ADR-009](009-queue-resume.md), [ADR-008](008-episode-downloads.md), [ADR-005](005-analysis-pipeline.md), [ADR-020](020-production-analysis-composition.md), [ADR-027](027-restore-now-playing-session.md) |

## Context

Manual Up Next and first-play analysis leave gaps: queue auto-advance is not fully
wired to a new cleaned session, and users wait on analysis between episodes.
Product wants seamless smart autoplay across subscriptions with binge vs episodic
rules and a small pre-warmed buffer so auto-advances rarely wait.

Offline bulk download / storage policy is **out of scope** (follow-up).

## Decision

### 1. Queue precedence

1. Non-empty manual Up Next → play next queued ID via full `playEpisode`.
2. Else if smart autoplay enabled → `SmartOrderEngine` next eligible.
3. Else stop and clear durable session (ADR-027).

### 2. Smart order

- Per-show **Binge** (`CDPodcast.isBinge`): oldest unplayed/eligible first; stay in
  show until exhausted. New episodes append at end of oldest-first order.
- Non-binge: least-recently-heard show rotation; take that show’s newest eligible.
- Binge shows participate in LRP rotation; once entered (rotation or manual), stay.
- Manual open of binge show enters binge; manual open of non-binge is one-off then
  global rotation resumes.
- **Skip / Next show**: dismiss current episode from autoplay forever
  (`CDEpisode.dismissedFromAutoplay`), advance to next **show** (exit binge turn).
- Eligible: not played, not dismissed; unfinished (`playbackPosition > 0`) allowed.
- Cleaning-off episodes remain eligible (no analyze). Analysis failure: retry once,
  then skip and continue.

### 3. Analysis timing carve-out

- Default remains: analyze on first play with cleaning when local file exists.
- **Additionally**: `WarmPlanner` may download + analyze the next **2–3** predicted
  autoplay episodes (pair), capped at **5** analyzed-but-unplayed warm slots.
- Warm starts when the current episode session begins; cancel/re-aim on Skip or
  order change.
- Manual play of a cold episode may still wait (unchanged).

### 4. Handoff miss

If next needs cleaning and is not ready: wait (optional spoken Preparing). Happy
path is instant handoff from warm cache.

### 5. Modules

| Module | Role |
|--------|------|
| `SmartOrderEngine` | Pure ordering / peek |
| `WarmPlanner` | Cap-5 pair download+analyze |
| `QueueCoordinator` | End / Skip → manual queue or smart next via `EpisodePlaying` |
| Settings | `smartAutoplayEnabled` |
| Schema | `isBinge`, `lastHeardAt`, `dismissedFromAutoplay` |

## Consequences

- Reopens analysis timing narrowly for warm slots only.
- Requires end-of-item wiring to `AppShellModel.playEpisode` (not bare `engine.play`).
- Download shelf / Wi‑Fi / storage caps remain a separate product session.
