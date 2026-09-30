# Queue Readiness UX — Canonical Implementation Plan

Status: **approved direction; implementation pending**.

This plan supersedes the earlier Queue preparation plan and the prior decision
in this file to keep ready rows visually quiet. Git history retains those older
designs; this document is the single source of truth for the next Queue change.

Queue remains an ordered listening commitment. Downloads remain a derived list
of audio files stored on this device, not a second queue. The change in this
plan is that storage, preparation, and immediate playability become explicit and
consistent everywhere they are shown.

## 1. Product contract

The app must answer two different questions without conflating them:

1. **Is the audio stored on this device?**
2. **Can it begin clean offline playback immediately?**

The exact promise is:

> **Ready to play offline** means a verified local audio file exists and all
> processing enabled for that episode/channel is complete.

`AnalysisJob.stage == .ready`, a persisted download flag, or an analysis cache
entry alone is never sufficient. The actual local file and the currently
required analysis artifacts are authoritative.

Do not display `100% ready`; percentages are reserved for measured download
progress. Do not display speculative time estimates such as "Usually a few
minutes." Use an indeterminate progress indicator for work whose progress is not
measured.

## 2. Existing behavior to preserve

- **Up Next** remains the sole listener-ordered list.
- **Downloads** remains a collapsed-by-default disclosure containing verified
  local files, excluding Now Playing, Up Next, and played episodes.
- Downloads remain ordered by preparation update, then publication date, with a
  deterministic episode-ID tie-break.
- Reorder mode, swipe removal, More menus, five-second Undo, Mark as Played,
  auto-delete behavior, and mini-player clearance remain unchanged.
- Selecting another episode keeps the interrupted episode first in Up Next and
  preserves the relative order of all other entries.
- Removing from Up Next never deletes completed local audio. **Remove download**
  deletes it explicitly; the existing auto-delete-after-played setting may also
  delete it when the Mark as Played Undo window commits.
- No Saved-for-Later entity and no Core Data migration are required.

## 3. Listener-facing Queue design

### Row layout

Every Up Next and Downloads row shows three distinct pieces of information:

1. Episode title, up to two lines.
2. Podcast title on its own secondary line.
3. A dedicated availability line containing an icon and the exact status copy
   from the table below.

Do not append availability to the podcast-title line; truncating the status would
recreate the original ambiguity. The availability line may wrap under large
Dynamic Type sizes. Color is supplemental only; icon and text carry the meaning.

Use these SF Symbols unless platform availability forces an equivalent:

| Meaning | Symbol | Default tint |
| --- | --- | --- |
| Ready | `checkmark.circle.fill` | green |
| Waiting/downloaded | `arrow.down.circle` | secondary/blue |
| Active preparation | `waveform` | accent |
| Checking ads | `magnifyingglass` | accent |
| Delayed | `clock` | orange |
| Needs attention | `exclamationmark.triangle.fill` | red |

### Exact status mapping

The derived status is deterministic. Evaluate conditions in the precedence
order defined in section 4; use this copy in Queue, Library, mini-player
accessibility values, and tests.

| Derived status | Visible copy | Indicator |
| --- | --- | --- |
| `waitingToDownload` | **Waiting to download** | none |
| `downloading(progress: nil)` | **Downloading** | indeterminate only if no measured value exists |
| `downloading(progress: p)` | **Downloading · N%** | determinate, `p` clamped to `0...1` |
| `downloadedNotPrepared` | **Downloaded · Not prepared** | none |
| `waitingToPrepare` | **Downloaded · Waiting to prepare** | none |
| `preparing` | **Preparing clean playback · On device** | indeterminate |
| `checkingAds` | **Checking for ads · On device** | indeterminate |
| `readyOffline` | **Ready to play offline** | none |
| `adCheckDelayed(retryAt: nil)` | **Ad check delayed · Retrying automatically** | none |
| `adCheckDelayed(retryAt: future)` | **Ad check delayed · Retrying in {duration}** | none |
| `adCheckDelayed(retryAt: past)` | **Ad check delayed · Retrying now** | none |
| `needsAttention` | **Needs attention** | none; show safe detail separately when available |

Retry duration uses the existing rounded listener-facing formatter. Never expose
raw errors, credentials, URLs, implementation stage names, or transcript data.

### Downloads disclosure

The label is two lines:

```text
Downloads (3)
2 ready · 1 preparing
```

Build the secondary summary from nonzero categories in this order: ready,
preparing, not prepared, delayed, needs attention. The category counts must sum
to the visible Downloads count. Allow the secondary line to wrap for Dynamic
Type rather than truncating it. Its accessibility value is the full spoken
summary, for example, "3 downloads: 2 ready to play offline, 1 preparing."

When expanded, show this short explanation before the first row:

> Saved on this device. Ready to play offline means clean-playback preparation
> is complete.

The empty state remains **Downloaded episodes will appear here.**

### Recovery actions

- Retryable failure: show **Retry now**.
- Ad detection delayed/failed after local cleaning is complete: show
  **Play without ad skipping**. Existing local profanity intervals remain active.
- General preparation failure where no cleaning result can be promised: show
  **Play original audio**. This is an explicit listener override; never invoke it
  from a normal row tap.
- Show either bypass action only when a verified local file exists. If no local
  audio exists, offer Retry only.
- Show **Play without ad skipping** only when the interval cache proves local
  profanity processing completed and the failed component is the cloud ad check.
  Otherwise the honest override is **Play original audio**.
- Do not use the generic **Play with ads** label for non-ad failures.

## 4. Shared availability model

Keep storage and preparation as separate facts, then derive a listener-facing
status. Do not encode all truth in display strings.

Add shared value types equivalent to:

```swift
enum LocalAudioAvailability: Equatable {
    case notDownloaded
    case downloading(progress: Double?)
    case downloaded
    case failed(detail: String?)
}

enum CleanPlaybackPreparation: Equatable {
    case notRequested
    case queued
    case preparing
    case checkingAds
    case ready
    case adCheckDelayed(retryAt: Date?)
    case needsAttention(detail: String?)
}

enum EpisodeReadinessStatus: Equatable {
    case waitingToDownload
    case downloading(progress: Double?)
    case downloadedNotPrepared
    case waitingToPrepare
    case preparing
    case checkingAds
    case readyOffline
    case adCheckDelayed(retryAt: Date?)
    case needsAttention(detail: String?)
}

struct EpisodeAvailability: Equatable {
    let localAudio: LocalAudioAvailability
    let preparation: CleanPlaybackPreparation
    let readiness: EpisodeReadinessStatus
}
```

Names may change to match project conventions, but the two source dimensions and
derived status must remain explicit.

Implement one pure `EpisodeAvailabilityResolver`. Its input must contain:

- `DownloadState` from `DownloadManager`;
- whether `DownloadManager.localFileURL(for:)` verified a real file;
- whether `WarmPlanner.isAnalysisReady(episodeID:feedURL:)` is true for current
  settings and channel cleaning configuration;
- the durable `AnalysisJob`, if any;
- the foreground preparation job, if it owns this episode.

Resolution precedence is mandatory:

1. A verified local file plus `isAnalysisReady == true` is `readyOffline`, even
   if a stale job still says transcribing, delayed, or ready.
2. Without a verified file, an active download is `downloading`.
3. Without a verified file, download failure or a terminal preparation failure
   is `needsAttention`; safe failure detail may be retained.
4. Without a verified file, all other requested states are
   `waitingToDownload`. A stale `.ready` job must never produce ready UI.
5. With a verified file but incomplete analysis, foreground job state takes
   precedence over the durable warm job because it owns the active request.
6. With a verified file, map transcribing, checking ads, delayed, failed, and
   queued jobs to their corresponding statuses.
7. With a verified file, incomplete analysis, and no active/queued job, return
   `downloadedNotPrepared`.

Place listener-facing copy, icons, progress behavior, summary category, and
accessibility wording in a separate pure presentation mapper. SwiftUI views must
not inspect `AnalysisJob`, `DownloadState`, cache files, or settings directly.

## 5. Reconciliation and source-of-truth fixes

Add a reconciliation pass at launch and whenever a foreground preparation
finishes:

- A persisted `.ready` job with no local file is not ready. If the episode is
  still requested by Up Next or automatic preparation, move it back to queued;
  otherwise remove the stale job.
- A local file with completed required analysis is ready regardless of stale job
  stage; update the durable job to `.ready` when a job exists.
- A local file without completed analysis and without a scheduled job remains
  downloaded/not prepared. Do not fabricate a queued job merely for display.
- A download-state record whose file is missing is reset through the existing
  `DownloadManager.localFileURL(for:)` repair behavior.

Fix `WarmPlanner.warmOne` so cleaning-disabled episodes still download their
audio before being marked `.ready`. "Cleaning is off" means no analysis is
required; it does not waive the offline-file requirement.

`WarmPlanner.quiesce()` must also clear `activeRequestIDs`. Otherwise re-aiming
the same selection after foreground work compares equal, returns early, and
leaves no worker running.

The same resolver must power:

- `QueuePresentationBuilder` rows and Downloads summary;
- the in-progress Library **Ready to Play** shelf;
- mini-player Queue/preparation accessibility status;
- autoplay/offline-ready eligibility.

Remove independent readiness logic from `ReadyToPlayChoice`. Library may filter
to `readiness == .readyOffline`, but it must consume the shared snapshot rather
than recompute readiness.

## 6. Queue presentation changes

Change `QueueEpisodePresentation` so it owns the resolved availability and its
pure status presentation instead of optional `activity` plus `isDownloaded`.
`QueuePresentation` also exposes a Downloads summary value with counts and
spoken copy.

`AppShellModel.queuePresentation` must:

1. Collect manual queue IDs and verified downloaded IDs.
2. Include download state for every manual item, including active progress and
   failures.
3. Resolve metadata, played state, feed URL, analysis readiness, durable job,
   and foreground job for each candidate.
4. Call `EpisodeAvailabilityResolver` once per candidate.
5. Pass resolved values into the pure `QueuePresentationBuilder`.

`QueuePresentationBuilder` retains current filtering and ordering rules. It does
not access stores, the filesystem, or singleton settings.

Refresh `queuePresentationRevision` on queue mutations, played-state changes,
download state/progress changes, preparation job changes, foreground stage
changes, cleaning-setting changes, and analysis completion. Coalesce progress
refreshes if necessary, but visible download progress must continue advancing.

## 7. Row activation and preparation ownership

Replace `playReadyEpisodeNow`/the Queue row callback with one operation whose
semantic name does not assume readiness, for example:

```swift
func activateQueueEpisode(_ episodeID: String)
```

It must work whether or not another episode is currently loaded.

### Queue mutation

Extend `QueueStore.prepareForImmediatePlayback` to accept an optional current
episode ID:

- Current episode `X`, selected `B`, queue `[A, B, C]` becomes `[X, A, C]`.
- No current episode, selected `B`, queue `[A, B, C]` becomes `[A, C]`.
- Selecting a downloaded item outside Up Next with current `X` inserts `X` at
  the front without inserting the selected item.
- Never duplicate the current or selected episode.

Do not mutate the queue when preparation merely starts. Keep the selected row in
its existing section so its progress remains visible, and keep the current audio
playing while the target downloads and prepares. Immediately before the ready
target becomes Now Playing, persist the mutation using the episode that is
current at that moment, then create the new playback session. This avoids silent
minutes, disappearing rows, and saving an episode that has already ended as the
one to resume.

### Latest-selection-wins contract

`AppShellModel` owns a monotonically increasing playback-intent generation and
at most one activation task. Each call to `activateQueueEpisode`:

1. Increments the generation and cancels the previous activation task.
2. Marks the selected episode as the pending Queue activation without removing
   it from its current presentation section.
3. Transfers preparation ownership safely and awaits a terminal outcome.
4. Rechecks that its generation is current after every suspension point.
5. On ready, applies the queue mutation above and starts playback only if the
   generation is still current.

Repeated taps on the same episode are idempotent. Selecting B while A is being
prepared guarantees A can never auto-play later. Removing the pending episode,
marking it played, removing its download, clearing Up Next, unsubscribing its
show, or dismissing the player cancels its pending playback intent.

### Background-to-foreground handoff

`WarmPlanner` and foreground playback share the analyzer, so they must never
analyze concurrently.

- If the selected episode is already ready, start from the local file
  immediately; do not restart analysis.
- Otherwise call a new structured async API equivalent to:

  ```swift
  enum ImmediatePreparationOutcome: Equatable {
      case ready
      case needsAttention
      case cancelled
  }

  func prepareImmediately(episodeID: String) async -> ImmediatePreparationOutcome
  ```

- `prepareImmediately` calls `quiesce()` and awaits the prior serial worker
  before using the existing `warmOne` download/analysis pipeline at
  user-requested priority. Cancellation alone is insufficient because
  URLSession/ASR adapters may observe it late.
- Refactor `warmOne` as needed to return a terminal outcome; do not create a
  second copy of its download, analysis, retry, or job-update logic.
- The activation task must own and await the download. It must not call the
  existing fire-and-forget `startDownloadBeforePlay`, because that task can
  finish after a newer selection and unexpectedly replace the player.
- Reuse any completed download or partial analysis artifacts already produced.
- The durable WarmPlanner job is the authoritative visible job while a Queue
  target prepares. `pendingQueueActivationEpisodeID` identifies the job that is
  expected to auto-play. Existing `foregroundPreparationJob` remains authoritative
  only for a playback session that already owns the episode.
- The current episode continues playing during this preparation. The mini-player
  Queue line reports the pending target's state; Queue and Library show the same
  job through the shared resolver.
- On success, reconcile the durable job to `.ready`, perform the queue mutation,
  load the prepared local episode, clear the pending intent, and start playback
  exactly once. The normal playback path must recognize the ready cache and must
  not perform the full analysis again. Then re-aim background warming.
- On cancellation, do not report failure and do not auto-play.
- Keep retries for immediate preparation structured under the activation task;
  do not schedule an unowned retry that can auto-play later. While retrying, the
  job publishes `adCheckDelayed` and waits using the injected `AppTiming`. A new
  selection or any cancellation condition terminates both the wait and the
  pending auto-play. The existing retry backoff schedule remains unchanged.
- On terminal failure, keep playback stopped and expose the recovery actions.

The new Queue activation generation protects the entire
quiesce/download/analyze/retry/queue-mutation/play sequence. Reuse the existing
`invalidatePlaybackPreparation()` request-ID guard only after a playback session
has taken foreground ownership.

## 8. Accessibility and interaction requirements

- Each row accessibility label is the episode title.
- Each row accessibility value includes podcast title, availability copy, and
  measured progress when present.
- Normal-mode hint: ready rows say **Plays now and keeps the current episode
  next.** Unready rows say **Prepares this episode, then plays it, and keeps the
  current episode next.**
- Reorder-mode hint remains **Reorder mode** and row activation stays disabled.
- Progress indicators have explicit labels and values; never announce both a
  parent percentage and a duplicate child percentage.
- More remains a separate 44-point target and must not trigger row playback.
- Status icons are hidden from accessibility when the same meaning is already in
  the row value.

## 9. Implementation sequence

1. Add the two-axis availability types, resolver, presentation mapper, and unit
   tests without changing the view.
2. Fix WarmPlanner's cleaning-off download invariant and add reconciliation.
3. Convert `QueuePresentationBuilder` and `AppShellModel.queuePresentation` to
   the shared availability snapshot; migrate Library and mini-player consumers.
4. Update Queue row layout, Downloads summary, accessibility, and recovery copy.
5. Implement optional-current queue mutation and the latest-selection-wins
   activation/handoff path.
6. Add integration and UI coverage, then run the focused and full verification
   suites.

Do not combine these steps with unrelated feed-refresh refactors. The working
tree currently contains feed-refresh/upcoming-preparation changes in shared
files; preserve them and integrate with their Library Ready to Play shelf rather
than reverting or duplicating them.

## 10. Validation requirements

### Availability resolver unit tests

Use table-driven tests covering at least:

- no file + no job -> waiting to download for requested Up Next item;
- active download at `0`, `0.42`, `1`, below `0`, and above `1` -> correctly
  clamped display percentage;
- file + no job + incomplete analysis -> downloaded/not prepared;
- file + queued job -> waiting to prepare;
- file + transcribing -> preparing;
- file + checking ads -> checking ads;
- file + complete required analysis -> ready offline;
- cleaning disabled + file -> ready offline;
- cleaning disabled + no file + `.ready` job -> not ready;
- missing file + `.ready` job -> not ready;
- file + stale transcribing job + completed analysis -> ready offline;
- foreground job overrides a conflicting durable nonterminal job;
- delayed retry before, at, and after `retryAfter`;
- download failure and terminal preparation failure -> needs attention;
- safe failure detail is preserved and raw diagnostic detail is not exposed.

### Presentation-builder unit tests

- Up Next preserves `QueueStore` order regardless of readiness.
- Downloads excludes Now Playing, Up Next, and played episodes.
- Downloads ordering remains deterministic.
- Every row has exactly one availability status; no nil/blank ready state exists.
- Summary categories omit zero counts and sum to the Downloads total.
- Summary visual and spoken copy are exact for ready-only, mixed, delayed,
  attention, and empty collections.
- Status icon, tint role, indicator style, visible copy, and accessibility copy
  match the mapping table.

### Planner and reconciliation tests

- Cleaning disabled still downloads before the job becomes ready.
- Ready job with a missing file is requeued when requested and removed when no
  longer requested.
- Completed artifacts repair a stale nonterminal job to ready.
- A local unprocessed file without a request remains not prepared and does not
  start work merely because Queue was opened.
- Launch reconciliation is idempotent and never duplicates work.
- Quiescing and then re-aiming the same request list starts a worker again;
  `activeRequestIDs` cannot suppress the restart.

### Activation and concurrency tests

- Ready local episode starts immediately without analyzer invocation.
- Downloaded/unprepared episode prepares and starts exactly once.
- Not-downloaded episode downloads, prepares, and starts exactly once.
- The current episode continues playing and the selected row remains visible
  while an unready target prepares.
- Activation works with no current player session.
- With current `X` and queue `[A, B, C]`, selecting B persists `[X, A, C]`.
- With no current and queue `[A, B, C]`, selecting B persists `[A, C]`.
- If X ends and Y becomes current while B prepares, switching to ready B queues
  Y, not the already-ended X.
- Rapid A-then-B selection can only start B.
- Repeated taps on B create one download, one analysis, and one playback start.
- A late completion from the old fire-and-forget download path cannot replace a
  newer selection; Queue activation uses only its owned structured task.
- Background preparation is fully settled before foreground analysis begins;
  assert maximum analyzer concurrency is one.
- Cancellation never becomes delayed/failed UI and never auto-plays later.
- Removing/playing/clearing/unsubscribing the pending episode invalidates its
  intent.
- Failure exposes the correct context-specific bypass action.
- Successful foreground completion updates Queue, Library, and mini-player to
  the same ready state before or when playback begins.

### UI tests

- Ready, downloaded/not-prepared, downloading, preparing, checking, delayed,
  and attention rows show the exact copy above.
- Downloads disclosure is collapsed initially, persists its expansion setting,
  and announces the correct summary.
- An unready selected row remains visible with live progress while the existing
  episode continues playing.
- Tapping an unready row visibly progresses and then plays without a second tap.
- Tapping a ready row plays immediately.
- Retry and bypass controls do not also trigger the row tap.
- Long titles, long podcast names, and every supported Dynamic Type size keep
  status readable and More/reorder controls hittable.
- VoiceOver reads title, podcast, status, progress, and the correct activation
  hint once each.
- Reorder, swipe removal, Undo, Mark as Played, auto-delete, mini-player
  clearance, and last-row scrolling continue to work.

### Regression and release gates

Run focused tests for Queue presentation, Queue store, WarmPlanner, production
analysis wiring, now-playing session restoration, Library, and the mini-player.
Then run the repository's normal full verification command. The change is not
complete if any focused test is skipped because of flakiness; fix or explicitly
quarantine with a documented existing issue.

Perform a manual device/simulator pass with:

1. one ready download;
2. one downloaded but unprepared episode;
3. one actively downloading episode;
4. one ad-check delay;
5. no current player session;
6. a playing episode interrupted by an unready Queue selection;
7. VoiceOver and an accessibility Dynamic Type size.

## 11. Definition of done

- A listener can distinguish downloaded, processing, and immediately playable
  episodes without opening a menu or inferring from missing text.
- **Ready to play offline** is truthful under stale persistence, missing files,
  disabled cleaning, retries, relaunch, and concurrent background work.
- Queue, Library, mini-player, and autoplay agree because they consume the same
  resolved availability.
- Selecting unfinished work cannot create concurrent analysis or surprise later
  playback.
- The two old Queue directions have been consolidated into this document, with
  no contradictory active plan remaining in `docs/plans`.
