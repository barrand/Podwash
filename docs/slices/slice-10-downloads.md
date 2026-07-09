# Slice 10 — Episode downloads

| Field | Value |
|-------|-------|
| **ID** | 10 |
| **Title** | Episode downloads |
| **Status** | Draft |
| **Crux** | Episodes download to the app sandbox with resumable progress, and playback prefers the local file — the prerequisite for cleaned playback of real episodes (ADR-000 §3: muting requires local files). |

## PRD / spec references

- PRD §2 — Download for offline listening
- `docs/adr/000-foundations.md` §3 — download-before-clean-listen constraint

## Goal

Reliable episode downloads feeding both offline listening and the cleaning pipeline.

## Deliverables

- `DownloadManager` (`URLSession` download tasks, injectable session), sandbox file layout, progress reporting
- Playback source resolution: local file if present, else stream (uncleaned)
- Download/delete UI affordance on episode rows (identifiers `downloadButton_<index>`, `downloadProgress_<index>`)
- `DownloadManagerTests` with `URLProtocol` stubs

## Depends on

- Slice 06

**Parallelizable:** Yes — with Slices 08, 09.

## Out-of-scope

- Auto-download/auto-delete policies (Slice 13 settings)
- Queue behavior (Slice 11)
- Cleaning integration beyond source resolution (Slice 08 owns it)

## Acceptance criteria

- [ ] 1. Unit test: stubbed download writes the file to the expected sandbox path; completion handler reports the local URL.
- [ ] 2. Unit test: progress callbacks are monotonically non-decreasing and end at 1.0 (stubbed chunked response).
- [ ] 3. Unit test: cancel mid-download leaves no partial file at the final path; resume data is retained when the stub provides it.
- [ ] 4. Unit test: source resolution returns the local URL when the file exists, remote URL otherwise.
- [ ] 5. UI test: tapping `downloadButton_0` (stubbed instant download) flips the row state to downloaded.
- [ ] 6. Full suite green via `scripts/verify.sh`.

## Verification mapping

| AC# | Test file | Test method | Notes |
|-----|-----------|-------------|-------|
| 1 | `PodWash/PodWashTests/DownloadManagerTests.swift` | `testDownloadWritesToSandbox` | TBD |
| 2 | `PodWash/PodWashTests/DownloadManagerTests.swift` | `testProgressMonotonic` | TBD |
| 3 | `PodWash/PodWashTests/DownloadManagerTests.swift` | `testCancelAndResumeData` | TBD |
| 4 | `PodWash/PodWashTests/DownloadManagerTests.swift` | `testSourceResolutionPrefersLocal` | TBD |
| 5 | `PodWash/PodWashUITests/DownloadUITests.swift` | `testDownloadButtonFlow` | Stubbed |
| 6 | — | — | Command-level |

## Verification commands

```bash
scripts/verify.sh -only-testing:PodWashTests/DownloadManagerTests -only-testing:PodWashUITests/DownloadUITests
scripts/verify.sh    # Done gate
```

## Verification record (QA fills at Verify)

```
VERIFY RESULT: (pending)
```

## Done gate

- [ ] Every AC mapped to a test; all rows filled
- [ ] **Full suite green:** unfiltered `scripts/verify.sh` exit 0, failed 0, skipped 0
- [ ] Verification record pasted above
- [ ] Auto-commit on green: `slice-10: <short description>`

## Role artifacts

| Role | Gate | Artifact path |
|------|------|---------------|
| Architect | Required | `docs/adr/` note on file layout + session injection (TBD) |
| UX | Light | identifiers list in slice file |
