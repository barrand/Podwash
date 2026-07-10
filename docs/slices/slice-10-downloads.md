# Slice 10 — Episode downloads

| Field | Value |
|-------|-------|
| **ID** | 10 |
| **Title** | Episode downloads |
| **Status** | Done |
| **Crux** | Stubbed `URLSession` downloads persist episode audio to a deterministic sandbox path with monotonic progress callbacks ending at **1.0**, and `PlaybackSourceResolver` returns that local file when present — the offline prerequisite for cleaned listening (ADR-000 §3: muting requires local files). |

## PRD / spec references

- PRD §2 — Streaming playback and download for offline listening
- PRD §9 — Client-direct fetch (`URLSession` on device); episode audio from public enclosure URLs
- `docs/adr/000-foundations.md` §3 — download-before-clean-listen constraint (muting unreliable on streams)

## Goal

Reliable episode downloads to the app sandbox with resumable progress and playback source resolution that prefers local files, feeding offline listening and the cleaning pipeline.

## Deliverables

- `DownloadManager` — `URLSession` background-capable download tasks, injectable `URLSession` / `URLProtocol` stub for tests, cancel + resume-data retention
- Deterministic sandbox layout: `{downloadsDirectory}/{episodeID}.m4a` (episode ID from Slice 06 `Episode.id`, e.g. `fixture-ep-001` for row 0)
- `PlaybackSourceResolver` (or equivalent) — returns local file URL when present on disk, else `Episode.audioURL`
- `InMemoryDownloadStateStore` — tracks per-episode download state for UI (Slice 11 migrates to durable store)
- Download/delete affordance on episode rows in `EpisodeListView` (extends Slice 06 list)
- **Accessibility identifiers** (UX-light; full spec in `docs/slices/slice-10-downloads-ux.md`):
  - `downloadButton_<index>` — 0-based row index (same convention as `episodeCell_<index>`)
  - `downloadProgress_<index>` — visible only while downloading
- **Launch-argument fixture mode** `-UITestFixtureDownload`: app completes downloads instantly from a bundled stub payload (no live network in UI tests; mirrors `-UITestFixtureFeed` / `-UITestFixtureAnalysis` pattern)
- Fixture `PodWash/PodWashTests/Fixtures/downloads/stub_episode_audio.bin` — **exactly 1024 bytes**, fixed byte pattern (provenance in fixture README); URLProtocol stub serves this payload in chunked responses for progress tests
- App-bundle copy of stub payload for `-UITestFixtureDownload` (`PodWash/PodWash/Fixtures/downloads/stub_episode_audio.bin`)
- `DownloadManagerTests`, `DownloadUITests`
- Architect decision: `docs/adr/008-episode-downloads.md` (file layout, session injection, cancel/resume contract)

## UI verification mechanism (decided)

**Accessibility asserts only** — no snapshots. UI tests assert identifiers, labels, and `accessibilityValue` strings. Download progress in UI tests uses the instant stub (`-UITestFixtureDownload`); unit tests cover chunked progress via `URLProtocol`.

## Depends on

- Slice 06 — `Episode.audioURL`, `episodeCell_<index>`, `-UITestFixtureFeed`, fixture feed with enclosure URLs (`https://fixture.podwash.tests/audio/alpha.m4a` for row 0)

**Parallelizable:** Yes — with Slices 11, 12 (parallel group B after Slice 08).

## Out-of-scope

- Auto-download and auto-delete-after-played policies (Slice 13 settings)
- Queue behavior, playback position persistence, or durable download-state persistence across relaunch (Slice 11)
- Cleaning / analysis pipeline integration beyond source resolution (Slice 08 owns playback coordinator wiring; this slice exposes the resolver only)
- Triggering one-time analysis on download (PRD §11 open decision — halt-and-ask if a slice tries to pick; not in this slice)
- Live network downloads in automated tests (`URLProtocol` stubs or `-UITestFixtureDownload` only)
- Background URLSession completion handlers / app relaunch while download in flight (post-MVP hardening)
- Streaming playback changes when no local file exists (unchanged uncleaned stream behavior)
- HLS-specific download handling (enclosure URLs from RSS fixtures are direct file URLs)
- Server-side proxy or backend of any kind (PRD §9)

## Acceptance criteria

Automatable only. **XCTSkip is not allowed on core ACs** — a mapped test that cannot run must fail.

- [x] 1. Unit test: stubbed download of episode `fixture-ep-001` (remote URL from fixture feed) writes a file at `{downloadsDirectory}/fixture-ep-001.m4a`; on-disk byte count **== 1024**; `download(…)` async return URL is `file://` and its path equals that file path **exactly**.
- [x] 2. Unit test: stub delivers the 1024-byte payload in **exactly 4** HTTP chunks; progress callback count **== 4**; each callback value is **≥** the previous (monotonic non-decreasing); final callback value **== 1.0**.
- [x] 3. Unit test: `cancel(episodeID:)` after **≥ 2** progress callbacks leaves **no file** at `{downloadsDirectory}/fixture-ep-001.m4a` (`FileManager.fileExists == false`); `resumeData(for:)` is **non-nil** with `count ≥ 1`.
- [x] 4. Unit test: `PlaybackSourceResolver` returns the local `file://` path when the sandbox file exists; returns `Episode.audioURL` when absent; after `deleteDownload(episodeID:)`, returns `Episode.audioURL` again (remote URL **exactly** equal to fixture enclosure URL for row 0).
- [x] 5. UI test (launch args `-UITestFixtureFeed` + `-UITestFixtureDownload`): before tap, `downloadButton_0` `accessibilityValue == "notDownloaded"` and `downloadProgress_0` does **not** exist; tap `downloadButton_0`; within **5 s**, `downloadButton_0` `accessibilityValue == "downloaded"` and `downloadProgress_0` does **not** exist; tap `downloadButton_0` again (delete); within **2 s**, `accessibilityValue == "notDownloaded"`.
- [x] 6. Full suite green via `scripts/verify.sh` with **exit 0, failed 0, skipped 0**.

## Verification mapping

| AC# | Test file | Test method | Notes |
|-----|-----------|-------------|-------|
| 1 | `PodWash/PodWashTests/DownloadManagerTests.swift` | `testDownloadWritesToSandbox` | `URLProtocol` stub returns `stub_episode_audio.bin` (1024 B); temp downloads directory; asserts path suffix `fixture-ep-001.m4a`, byte count, async return URL path |
| 2 | `PodWash/PodWashTests/DownloadManagerTests.swift` | `testProgressMonotonicEndsAtOne` | Stub serves 4 equal chunks; asserts callback count == 4, monotonic values, final == 1.0 |
| 3 | `PodWash/PodWashTests/DownloadManagerTests.swift` | `testCancelRemovesPartialAndRetainsResumeData` | `cancel(episodeID:)` after ≥ 2 callbacks; `fileExists == false` at final path; `resumeData(for:)` non-nil, `count ≥ 1` |
| 4 | `PodWash/PodWashTests/DownloadManagerTests.swift` | `testSourceResolutionAndDelete` | Resolver local vs remote; delete restores remote `https://fixture.podwash.tests/audio/alpha.m4a` for row 0 |
| 5 | `PodWash/PodWashUITests/DownloadUITests.swift` | `testDownloadAndDeleteButtonFlow` | `-UITestFixtureFeed` + `-UITestFixtureDownload`; initial `notDownloaded`; download within 5 s; delete within 2 s |
| 6 | — | — | Command-level: unfiltered `scripts/verify.sh` exit 0, failed 0, skipped 0 |

## Verification commands

```bash
# Fast inner loop (NOT sufficient for Done):
scripts/verify.sh -only-testing:PodWashTests/DownloadManagerTests -only-testing:PodWashUITests/DownloadUITests

# Done gate — FULL suite, zero failures, zero skips:
scripts/verify.sh
```

## Verification record (QA fills at Verify)

> Paste the `VERIFY RESULT:` line from the full-suite `scripts/verify.sh` run here.
> A slice without a recorded full-suite green artifact is not Done.

```
VERIFY RESULT: exit=0 total=45 passed=45 failed=0 skipped=0 filtered=0 bundle=build/test-results/verify-20260710-091512.xcresult
```

## Plan review record (coordinator fills before downstream roles)

> Record readonly review outcomes before QA writes tests (ADR review) and before
> Engineer starts (test spec review). No record = next role must not spawn.
> See [`multitask-workflow.md`](../multitask-workflow.md) § Plan review gates.

```
ADR review (2026-07-09): QA cleared — normative StubDownloadURLProtocol contract (async 4-chunk delivery, cancel sync gate, resume data) makes AC2/AC3 deterministic offline; empirical validation section replaces waived spike. PM cleared — ADR path synced to 008-episode-downloads.md; ACs aligned with ADR §9; crux intact.
Test spec review (2026-07-09): Architect cleared — AC1–AC5 map to ADR-008 public APIs; normative StubDownloadURLProtocol satisfies AC2/AC3 determinism contract; UI harness matches a11y contract.
```

## Done gate

- [x] Every AC mapped to a test; all rows in the mapping table filled
- [x] **Full suite green:** unfiltered `scripts/verify.sh` exit 0, failed 0, skipped 0
- [x] Verification record pasted above (exit code + counts + `.xcresult` path)
- [x] Auto-commit made on green: `slice-10: <short description>` (push only when the user asks)

## Role artifacts

| Role | Gate | Artifact path |
|------|------|---------------|
| PM | Required | `docs/slices/slice-10-downloads.md` (this file) |
| Architect | Required | `docs/adr/008-episode-downloads.md` — sandbox layout, injectable session, cancel/resume contract |
| UX | Light | `docs/slices/slice-10-downloads-ux.md` — download/delete identifiers + `accessibilityValue` contract |
| QA | Required | `PodWash/PodWashTests/DownloadManagerTests.swift`, `PodWash/PodWashUITests/DownloadUITests.swift`, `PodWash/PodWashTests/Fixtures/downloads/stub_episode_audio.bin` |
| Engineer | Required | `DownloadPaths.swift`, `DownloadManager.swift`, `PlaybackSourceResolver.swift`, `InMemoryDownloadStateStore.swift`, `FixtureDownload.swift`, `EpisodeListView` wiring |
