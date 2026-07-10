# Architecture Decision Records

Durable technical decisions for PodWash. One markdown file per decision, numbered
`NNN-short-title.md`. ADRs are written by the Architect role **before**
implementation on slices that add modules or change shared APIs, and are referenced
from the relevant slice file's Role artifacts table.

| Rule | Detail |
|------|--------|
| **Format** | Context → Decision → Consequences (keep it short; a page is plenty) |
| **Status** | `Accepted`, `Superseded by NNN`, or `Deferred` in the header |
| **Change** | Never rewrite an accepted ADR's decision — write a new ADR that supersedes it |
| **Scope** | Cross-slice technical decisions only; slice-local layout goes inline in the slice file |

## Index

| # | Title | Status |
|---|-------|--------|
| [000](000-foundations.md) | Foundations: playback, verification, transcript schema, iOS floor | Accepted |
| [001](001-playback-engine.md) | Playback engine module boundaries | Accepted |
| [002](002-interval-scheduler.md) | Interval scheduler: mute mix + skip | Accepted |
| [003](003-asr-stack-choice.md) | On-device ASR stack choice: WhisperKit (Core ML) tiny.en | Accepted |
| [004](004-rss-parser.md) | RSS parser, episode list, and fixture-feed mode | Accepted |
| [005](005-analysis-pipeline.md) | Analyze-episode pipeline: ASR → matcher → cache | Accepted |
| [006](006-playback-integration.md) | Playback integration: cache → scheduler → engine | Accepted |
| [007](007-persistence-core-data.md) | Local persistence: Core Data | Accepted |
| [008](008-episode-downloads.md) | Episode downloads: sandbox layout, session injection, source resolution | Accepted |
| [009](009-queue-resume.md) | Queue + resume: stores, coordinator, reload | Accepted |
