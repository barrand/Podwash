# Task 030 — Retain completed episode analysis across navigation

| Field | Value |
|-------|-------|
| **ID** | 030 |
| **Title** | Retain completed episode analysis across navigation |
| **Status** | In Progress |
| **Kind** | fix |
| **Priority** | P1 |
| **Area** | `PodWash/PodWash/AnalysisPipeline.swift`, `PodWash/PodWash/IntervalCache.swift`, `PodWash/PodWash/TranscriptCache.swift`, `PodWash/PodWash/AppShellModel.swift`, `PodWash/PodWashTests/AnalysisPipelineTests.swift` |
| **Crux** | After a completed analysis, leaving an episode and returning to it must reuse its persisted transcript and analysis result rather than starting another cloud ad-detection request. |

## Outcome

**Observed (device, 2026-07-24):** After waiting for an episode to finish analysis,
starting playback, opening another episode, and returning to the original one,
PodWash shows the analysis cycle again. This can make a completed episode look
unfinished and can send unnecessary cloud requests.

**Expected:** Analysis belongs to the persisted episode download. Returning to an
episode that has not been deleted reuses its valid completed result immediately;
it does not restart Whisper transcription or Gemini ad detection. Deleting the
episode may remove this local result and a later fresh download may analyze again.

## Acceptance criteria

- [ ] 1. Unit test: analyze a downloaded fixture episode with local Whisper and a cloud-ad client spy, then construct a fresh pipeline/app navigation path for the same undeleted episode. The second path returns the persisted intervals and transcript without invoking either transcription or the cloud client a second time.
- [ ] 2. Unit test: remove the episode's persisted local analysis artifacts through the existing delete/cleanup path, then analyze the same episode again. The pipeline is permitted to perform fresh transcription and cloud detection, proving retention is scoped to an undeleted local episode rather than a stale global result.
- [ ] 3. The cache-hit path remains valid when the completed analysis contains zero unrelated-content/ad spans: it must use an explicit completion record rather than treating an empty interval list as "not analyzed".

## Surgical test scope

| AC# | Test id | New? |
|-----|---------|------|
| 1 | `PodWashTests/AnalysisPipelineTests/testCompletedAnalysisSurvivesNewPipelineForUndeletedEpisode()` | yes |
| 2 | `PodWashTests/AnalysisPipelineTests/testDeletedEpisodeDoesNotReuseCompletedAnalysis()` | yes |
| 3 | `PodWashTests/AnalysisPipelineTests/testCompletedEmptyCloudAnalysisIsReused()` | yes |

## Authorized test changes

- (none — bug fix; retain existing cache invalidation and deletion expectations)

## Depends on

- None

## Out of scope

- A backend per-install monetary cap.
- Changing the 180-day server-side Gemini-result cache retention.
- Reprocessing an episode because its model/prompt/schema pipeline version changes.
- Persisting analysis after the user deletes the downloaded episode.

## Human checklist

- (none — automatable)

## Verification record

> Loop writes `VERIFY RESULT:` here. For tasks, `tier=2` and `filtered=1` are valid for Done.

```
VERIFY RESULT: exit=0 total=11 passed=11 failed=0 skipped=0 filtered=1 bundle=build/test-results/verify-20260725-001720.xcresult tier=2 class=tests
```
