# Task 001 — Episode download fails on device after spinner

| Field | Value |
|-------|-------|
| **ID** | 001 |
| **Title** | Episode download fails on device after spinner |
| **Status** | Done |
| **Kind** | fix |
| **Priority** | P1 |
| **Area** | `PodWash/PodWash/DownloadManager.swift`, `PodWash/PodWash/EpisodeListView.swift`, `PodWash/PodWashTests/DownloadManagerTests.swift`, `PodWash/PodWashTests/StubDownloadURLProtocol.swift` |
| **Crux** | A real-network episode download on device ends in `.downloaded` with a sandbox `.m4a` file — not `.failed` with the red exclamation affordance. |

## Outcome

**Observed (physical device, 100% repro):** Library → open a subscribed show → episode list → tap the download button (`downloadButton_<index>`, `arrow.down.circle`). Row shows the downloading spinner and “Downloading…” copy (`downloadProgress_<index>` visible, `accessibilityValue == "downloading"`). Shortly after, the button turns red with `exclamationmark.circle`, `accessibilityValue == "failed"`, hint “Download failed. Tap to retry.”

**Expected:** Download completes; spinner hides; button shows `trash.circle`, `accessibilityValue == "downloaded"`; audio file exists at `{downloadsDirectory}/{episodeID}.m4a` per ADR-008.

**Test gap:** `DownloadUITests.testDownloadAndDeleteButtonFlow` uses `-UITestFixtureDownload` (synchronous bundled stub, no `URLSession`). `DownloadManagerTests` use `StubDownloadURLProtocol` against `fixture.podwash.tests` with a single 200 response — neither exercises production `URLSessionDownloadTask` behavior against realistic podcast enclosure transports (redirects, CDN headers, temp-file move). That is why CI is green while device downloads always fail.

## Acceptance criteria

- [ ] 1. Unit test: `DownloadManager.download` against a stub that returns **HTTP 302** to a second URL, then **200** with `Content-Length` and a non-empty body, finishes with `state(for:) == .downloaded` and a file at `DownloadPaths.localFileURL` with `Data.count ≥ 1`.
- [ ] 2. Unit test: same manager API when the stub returns a non-recoverable transport error (e.g. HTTP 500) leaves `state(for:) == .failed` and **no** file at the final `.m4a` path (`FileManager.fileExists == false`).
- [ ] 3. On physical device (human spot-check after AC 1–2 green): repeat Library → show → episode list download once; button reaches `downloaded` within **120 s** on Wi‑Fi for a subscribed episode with a known-good enclosure URL.

## Surgical test scope

| AC# | Test id | New? |
|-----|---------|------|
| 1 | `PodWashTests/DownloadManagerTests/testDownloadCompletesAfterHTTPRedirect()` | yes |
| 2 | `PodWashTests/DownloadManagerTests/testDownloadMarksFailedOnTransportError()` | yes |
| 3 | — (device checklist below) | — |

## Authorized test changes

- (none — bug fix)

## Depends on

- None

## Out of scope

- Auto-download / auto-delete settings (Slice 13)
- Background `URLSession` completion across app relaunch
- HLS segment downloads (RSS enclosures are direct file URLs per Slice 10)
- Changing the failed-state UX copy or icon (keep `exclamationmark.circle` / `accessibilityValue == "failed"`)

## Human checklist

- [ ] Build to physical device from green tier-2 verify.
- [ ] Library → any subscribed show → episode list → tap download on one episode.
- [ ] Within 120 s on Wi‑Fi: no red exclamation; button shows delete/trash affordance; episode plays from local file if offline afterward.

## Verification record

> Loop writes `VERIFY RESULT:` here. For tasks, `tier=2` and `filtered=1` are valid for Done.

```
VERIFY RESULT: exit=0 total=2 passed=2 failed=0 skipped=0 filtered=1 bundle=build/test-results/verify-20260713-131822.xcresult tier=2 class=tests
```
