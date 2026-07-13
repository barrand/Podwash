# Task 007 — Device episode download still fails (silent)

| Field | Value |
|-------|-------|
| **ID** | 007 |
| **Title** | Device episode download still fails (silent) |
| **Status** | In Progress |
| **Kind** | fix |
| **Priority** | P1 |
| **Area** | `PodWash/PodWash/DownloadManager.swift`, `PodWash/PodWashTests/DownloadManagerTests.swift` |
| **Crux** | On a physical iPhone (Wi‑Fi), tapping download on a subscribed episode reaches `downloadButton_*` `accessibilityValue == "downloaded"` within **120 s** — not `"failed"` / red `exclamationmark.circle`. |

## Outcome

**Observed (physical iPhone, 100% repro):** Library → subscribed show → episode list → tap `downloadButton_<index>`. UI ends in failed affordance (red `exclamationmark.circle`, `accessibilityValue == "failed"`). No PodWash / `DownloadManager` lines appear for the failure: `failDownload` has no `Logger`/`print`, and Console.app was showing **Simulator** system noise (`CoreSimulator`, `proactiveeventtrackerd`) rather than the phone’s `PodWash` process.

**Expected:** Same tap ends in `downloaded` (trash affordance) with a sandbox `.m4a` per ADR-008. If a download *does* fail, Console filtered to process **PodWash** shows one OSLog line with the underlying `Error` (domain/code/description), and `DownloadManager` retains a queryable last-failure diagnostic for that episode ID.

**Relation to task-001 (Done):** Same UX symptom. Task-001 only ignored late `didCompleteWithError` when the `.m4a` already existed (`d4992ab`). Repro continuing implies a **different** failure path (HTTP non-2xx, move error, missing `audioURL`, ATS/TLS, bad enclosure, etc.) and/or a build that still needs the device checklist against **HEAD**. Do not close this by re-asserting the redirect unit test alone.

**Test gap:** `testDownloadCompletesAfterHTTPRedirect` / `testDownloadMarksFailedOnTransportError` and fixture UI downloads never exercise production device enclosures, and nothing asserts that a failure leaves a diagnostic string.

## Acceptance criteria

- [ ] 1. Unit test: when a stubbed download ends in transport failure (existing 500 / error path), `state(for:) == .failed` **and** `lastFailureDiagnostic(for: episodeID)` (name flexible) is a **non-empty** `String` that includes either the underlying error `localizedDescription` or `NSError` domain+code.
- [ ] 2. Unit test: successful redirect download (existing happy path) leaves `lastFailureDiagnostic(for:)` **nil** (or empty) for that episode after `.downloaded`.
- [ ] 3. Human: on physical iPhone from a build that includes this task’s app changes + task-001: Library → subscribed show → tap download once on Wi‑Fi; within **120 s**, button is `downloaded` (no red exclamation). If it still fails, capture the new OSLog / diagnostic string and **Halt** with that text in the verification record (do not mark Done).

## Surgical test scope

| AC# | Test id | New? |
|-----|---------|------|
| 1 | `PodWashTests/DownloadManagerTests/testFailedDownloadExposesNonEmptyDiagnostic()` | yes |
| 2 | `PodWashTests/DownloadManagerTests/testSuccessfulDownloadClearsFailureDiagnostic()` | yes |
| 3 | — (device checklist below) | — |

## Authorized test changes

- (none — bug fix; may add APIs under test, do not weaken existing download assertions)

## Depends on

- Task 001 (Done) — late-complete race guard must remain; this ticket addresses remaining silent device failures

## Out of scope

- Teaching humans Console.app (document only in checklist)
- Surfacing failure reason in production UI copy beyond existing “Download failed. Tap to retry.”
- Background `URLSession` across relaunch / HLS
- Changing success icon/value contracts (`trash.circle` / `downloaded`)

## Human checklist

- [ ] Build to **physical iPhone** from green tier-2 (not Simulator-only).
- [ ] Mac **Console.app**: select the **iPhone** device (not a Simulator), filter process **`PodWash`**, clear, then tap download.
- [ ] Within 120 s on Wi‑Fi: no red exclamation; `downloaded` affordance.
- [ ] If still failed: paste the PodWash OSLog / `lastFailureDiagnostic` line into the verification record and set Status **Halted**.

## Verification record

> Loop writes `VERIFY RESULT:` here. For tasks, `tier=2` and `filtered=1` are valid for Done.

```
VERIFY RESULT: exit=0 total=2 passed=2 failed=0 skipped=0 filtered=1 bundle=build/test-results/verify-20260713-170008.xcresult tier=2 class=tests
```
