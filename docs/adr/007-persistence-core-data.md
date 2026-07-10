# ADR-007 — Local persistence: Core Data

| Field | Value |
|-------|-------|
| **Status** | Accepted |
| **Date** | 2026-07-09 |
| **Supersedes** | — |
| **Builds on** | [ADR-000](000-foundations.md) §6 (`scripts/verify.sh`-only); [ADR-004](004-rss-parser.md) (`InMemoryPodcastStore` stub); [ADR-005](005-analysis-pipeline.md) (`IntervalCache` JSON) |
| **Resolves** | PRD §11 open decision — local persistence stack (SwiftData vs Core Data) |

## Context

Slice 11 is the first slice that commits to durable on-device storage for
subscriptions, episode metadata, queue order, playback positions, played state,
and cleaning toggles (migrating Slice 06/09 in-memory stubs). PRD §7 listed
"SwiftData or Core Data (TBD)" and PRD §11 required an explicit product decision
before implementation.

The user chose **Core Data** for predictable in-memory test configuration,
explicit schema versioning, and mature XCTest patterns in the dark-factory pipeline.

The Xcode project currently includes a **SwiftData template scaffold**
(`PodWashApp.swift` `ModelContainer`, `Item.swift`). That scaffold is unused by
feature code and is **removed in Slice 11** when Core Data is wired.

## Decision

### 1. Stack — Core Data via `NSPersistentContainer`

- Persistence uses **Core Data** with a versioned `.xcdatamodeld` and
  `NSPersistentContainer` (or thin wrapper) injected into stores and view models.
- **No SwiftData** for PodWash persistence.
- **No CloudKit sync** (PRD §9: client-direct, on-device only).

### 2. Scope (Slice 11)

Durable entities (names may refine during implementation):

| Concern | Migrates from |
|---------|----------------|
| Subscriptions + episode metadata | `InMemoryPodcastStore` (Slice 06) |
| Channel + episode cleaning toggles | `InMemoryCleaningToggleStore` (Slice 09) |
| Up-next queue order | new |
| Playback position + played/unplayed | new |
| Interval cache (optional in 11) | `IntervalCache` JSON files (ADR-005) — key semantics `(episodeID, fingerprint)` carry forward if moved |

### 3. Test configuration

- Unit tests use an **in-memory** `NSPersistentStoreDescription`
  (`isStoredInMemoryOnly = true`) on a dedicated container instance — fast,
  isolated, reloadable per AC in `slice-11-queue-resume.md`.
- No test may depend on disk state left by a prior test.

### 4. Module layout (Slice 11 — sketch)

| File | Responsibility |
|------|----------------|
| `PodWash.xcdatamodeld` | Versioned schema |
| `PersistenceController.swift` (or equivalent) | Container factory; production vs in-memory |
| `PodcastStore.swift` (or equivalent) | Core Data–backed replacement for `InMemoryPodcastStore` |
| `CleaningToggleStore.swift` (or equivalent) | Core Data–backed replacement for `InMemoryCleaningToggleStore` |
| `QueueStore.swift` / resume helpers | Queue + position persistence |

Exact file names are slice deliverables; boundaries must keep fetch/save logic
testable without SwiftUI.

## See also

- [ADR-009](009-queue-resume.md) — Slice 11 module boundaries, store/coordinator APIs,
  schema, played threshold, and reload pattern (builds on this ADR).

## Consequences

- This ADR resolves the Core Data stack choice. Slice 11 implementation APIs are
  specified in ADR-009; Engineer implements against both after QA test spec +
  Architect test-spec review.
- Forward-looking references in ADR-004/005 and slice docs that assumed SwiftData
  are updated to Core Data.
- `scripts/next-slice.sh` **HALT_SLICES** no longer includes slice 11.
- Removing the SwiftData template (`Item.swift`, `ModelContainer` in
  `PodWashApp.swift`) is part of Slice 11 implementation — not this ADR.

## Alternatives considered

| Option | Why not chosen |
|--------|----------------|
| **SwiftData** | Simpler SwiftUI ergonomics, but less proven in-memory XCTest patterns and opaque over Core Data when debugging persistence failures. |
| **JSON/files only** | Insufficient for relational queue/order queries and concurrent access patterns as features grow. |
