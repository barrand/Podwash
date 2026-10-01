# Shared Library + Queue Episode Readiness UI

Status: **approved direction; implementation pending**.

This document is the canonical plan for the next Library and Queue readiness
change. It supersedes the prior Ready to Play shelf, the Queue Downloads
disclosure, separate UIKit/SwiftUI episode rows, permanent Library accessory
buttons, and the implicit "prepare, then play" interaction.

## 1. Product contract

Library and Queue have separate, simple jobs:

- **Library** is the catalog of subscribed shows. A show screen contains its
  episodes.
- **Queue** is the listener's ordered **Up Next** list. It contains no global
  Downloads inventory.

Both surfaces render an episode through the exact same row component and the
same action handlers. Context changes only the row's secondary metadata and
collection-management actions.

The governing interaction rule is:

> Show **Play** only when playback can start immediately. Otherwise show the
> exact action or passive state that moves the episode toward readiness.

**Ready to play offline** requires both a verified local audio file and every
currently enabled preparation artifact for that episode/channel. A persisted
download flag, `.ready` job, or cache entry alone is insufficient. The
filesystem and current preparation requirements are authoritative.

## 2. Final row design

### Shared component

Create one SwiftUI `EpisodeRowView`. Queue uses it directly. Library's existing
`UITableViewController` hosts the same view with `UIHostingConfiguration` so the
app retains its feed refresh, transcript refresh, scrolling, and embedding
behavior without preserving a second row implementation.

The row contains:

1. title, up to two lines;
2. context metadata—podcast title in Queue; publication date and Played state in
   Library;
3. one listener-facing availability line;
4. the existing completed cleaning summary when applicable;
5. one trailing **primary-state slot**;
6. one trailing **More** button.

The primary-state slot is the only readiness visualization. Do not show a
second progress bar beneath the status and a progress ring at the same time.
The status line supplies the words; the slot supplies the action or activity:

```text
Download -> progress -> processing -> Play
                    \-> failure -> Retry
```

The More button stays in a fixed trailing position. The row body is
informational and never starts playback or preparation. In Queue reorder mode,
primary and More yield to the reorder interaction.

All interactive targets are at least 44 points. Status text may wrap at Dynamic
Type sizes. Color is supplemental; visible words and symbols carry meaning.

### Exact state mapping

| Resolved readiness | Visible status | Primary-state slot |
| --- | --- | --- |
| `notDownloaded` | **Not downloaded** | **Download** |
| `waitingToDownload` | **Waiting to download** | passive clock |
| `downloading(progress: nil)` | **Downloading** | indeterminate progress |
| `downloading(progress: p)` | **Downloading · N%** | determinate progress, clamped to `0...1` |
| `downloadedNotPrepared` | **Downloaded · Not prepared** | **Prepare** |
| `waitingToPrepare` | **Downloaded · Waiting to prepare** | passive clock |
| `preparing` | **Preparing clean playback · On device** | indeterminate activity |
| `checkingAds` | **Checking for ads · On device** | indeterminate activity |
| `readyOffline` | **Ready to play offline** | **Play** |
| `adCheckDelayed(retryAt: nil)` | **Ad check delayed · Retrying automatically** | passive clock |
| `adCheckDelayed(retryAt: future)` | **Ad check delayed · Retrying in {duration}** | passive clock |
| `adCheckDelayed(retryAt: past)` | **Ad check delayed · Retrying now** | passive clock |
| download failure | **Download failed** | **Retry** |
| preparation failure | **Preparation needs attention** | **Retry** |

Only measured download progress receives a percentage. Do not fabricate
analysis percentages or duration estimates.

### Action semantics

- **Download** starts the complete download-and-preparation pipeline and ends at
  verified Ready to play. It does not add the episode to Up Next.
- **Prepare** continues the same pipeline from an already verified local file.
- **Retry** retries the failed stage without creating a second download or
  analyzer run.
- **Play** re-resolves readiness and starts verified local audio immediately. A
  stale tap after readiness is lost does not start remote or unprepared audio.
- Delayed automatic retries remain passive. **Retry now** and safe playback
  overrides live in More.
- Repeated taps are idempotent.
- Safe errors may be retained for diagnostics, but raw URLs, credentials,
  transcript content, and internal stage names never appear in the row.

### More menu

Shared actions use identical wording and behavior in Library and Queue. Order
them as Queue membership, active-work/recovery, transcript, played state, then
destructive local-audio removal.

Applicable shared actions are:

- **Cancel Download** or **Cancel Preparation** when an explicit request owns
  cancellable work;
- **Retry now** for delayed work;
- **Play without ad skipping** only when verified local profanity processing is
  complete and the failed/delayed component is the cloud ad check;
- **Play original audio** when a verified local file exists but no cleaning
  result can honestly be promised;
- **View Transcript** when available;
- **Mark as Played** or **Replay from Beginning** when applicable;
- **Remove Download**, destructive, when local audio exists.

Safe playback overrides appear on both Library and Queue. Omit inapplicable
items rather than disabling them. Do not duplicate Download, Prepare, Retry, or
Play in More when the primary-state slot already exposes that action.

The only context-specific actions are:

- Library: **Add to Up Next** or **Remove from Up Next**;
- Queue: **Move to Top**, **Remove from Up Next**, and reorder support.

## 3. Shared presentation and action interfaces

Keep storage, preparation, listener presentation, and UI actions separate.

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
    case notDownloaded
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

enum EpisodePrimaryControl: Equatable {
    case download
    case prepare
    case waiting
    case progress(Double?)
    case retry
    case play
}
```

`EpisodeAvailabilityResolver` is pure. Its input includes download state,
verified-file presence, current analysis readiness, durable and foreground jobs,
and whether work has an active owner. It applies this precedence:

1. verified file plus current required analysis -> ready offline;
2. no file plus active download -> downloading;
3. no file plus download/terminal failure -> needs attention;
4. no file plus active owner -> waiting to download;
5. no file plus no owner -> not downloaded;
6. verified file plus current job -> job-derived preparation state;
7. verified file plus incomplete analysis and no job -> downloaded/not prepared.

Create one pure `EpisodeRowPresentationMapper`. It is the only source of visible
status copy, symbols, semantic tint, progress presentation, primary control,
safe failure copy, menu eligibility, and accessibility wording.

`EpisodeRowView` receives value-only inputs equivalent to:

```swift
EpisodeRowView(
    presentation: EpisodeRowPresentation,
    context: EpisodeRowContext,
    actions: EpisodeRowActions
)
```

It does not receive `DownloadManager`, `WarmPlanner`, `AnalysisJob`, settings,
or persistence stores.

Expose one shared action surface from `AppShellModel`:

```swift
requestEpisodeDownload(_ episodeID: String)
prepareDownloadedEpisode(_ episodeID: String)
retryEpisodePreparation(_ episodeID: String)
playReadyEpisode(_ episodeID: String, context: EpisodePlayContext)
cancelEpisodePreparation(_ episodeID: String)
removeEpisodeDownload(_ episodeID: String)
addToUpNext(_ episodeID: String)
removeFromUpNext(_ episodeID: String)
```

Every handler re-resolves state before mutating anything.

## 4. Preparation ownership

Keep the existing serial `WarmPlanner`; change its request inputs rather than
building another preparation engine.

### Automatic readiness window

**Keep episodes ready automatically** prepares only the first two eligible
choices, matching the setting's existing listener-facing promise.

- Queue order wins when selecting the two choices.
- Predictions fill unused slots only when existing smart-autoplay rules permit.
- An automatic choice waiting for the worker shows Waiting to download and no
  Download button because work is already requested.
- Other queued episodes remain Not downloaded with Download.
- With the setting off, Queue episodes remain idle unless another explicit
  owner requires them.
- Reordering recomputes the automatic window.
- Work leaving the window stops when automatic preparation was its only owner.
- Completed local audio remains; resumable partial-transfer data may remain
  internal.

### Explicit intent and automatic suppression

Use one versioned UserDefaults payload and one store:

```swift
struct EpisodePreparationPreferences: Codable {
    var explicitEpisodeIDs: Set<String>
    var automaticallySuppressedEpisodeIDs: Set<String>
}
```

The store is the durable source for listener intent; `AnalysisJob` remains the
durable description of pipeline progress.

- Insert explicit intent before Download or Prepare starts.
- Reconstruct ownership on launch from explicit IDs, current automatic choices,
  and replay/current-playback requirements.
- Clear explicit intent after verified readiness, explicit cancellation, Remove
  Download, unsubscribe, or local-data cleanup.
- Remove Download on an automatically owned episode adds suppression so the app
  does not immediately redownload it.
- Suppression clears when the episode leaves the automatic window or the
  listener explicitly taps Download.
- Queue membership does not create or erase explicit Download intent.
- Cancelling one owner stops work only when no other owner remains.

Planner priority is replay/current playback requirements, explicit Download or
Prepare requests, the automatic next-two window, then predictions. All owners
share one download and one analyzer run.

## 5. Screen changes

### Library root

Keep subscription artwork/title, navigation, unsubscribe, empty state, refresh,
and compact partial-refresh failure. Remove every episode-readiness shelf and
Queue shortcut.

### Library show

Host the shared row in the existing table. Refresh a visible row whenever its
download state/progress, planner job, analysis readiness, cleaning setting,
queue membership, transcript availability, or played state changes.

Use self-sizing cells. Preserve pull-to-refresh, long-list scrolling, transcript
backfill refresh, and zero-width embedding safeguards.

### Queue

Queue contains one Up Next section only. Remove the Downloads disclosure and
all global downloaded-episode summary/filtering behavior.

Preserve saved order, reorder mode, Move to Top, swipe removal, five-second
Undo, Mark as Played, auto-delete-after-played, mini-player clearance, and the
empty state.

The mini-player Queue status button continues to open Queue. It consumes the
same availability presentation but does not render `EpisodeRowView`.

## 6. Required old-code removal

Implementation is incomplete until the obsolete presentation and behavior
paths below are deleted rather than left behind as compatibility code.

### Remove the Library Ready to Play shelf

Delete:

- `ReadyToPlayChoice`;
- `readyToPlayChoices`;
- `preparationShelfStatus`;
- `playReadyChoice`;
- `LibraryView.readyChoices`;
- `LibraryView.preparationStatus`;
- `LibraryView.onPlayReadyChoice`;
- `LibraryView.onOpenQueue`;
- Ready to Play markup and `readyToPlay_*` identifiers;
- Library-root Queue/View Queue buttons;
- corresponding `AppShellView` parameters and closures.

### Remove the old Library episode cell

Delete the custom `EpisodeTableViewCell` presentation implementation, including:

- manual title/date/status/accessory constraints and fixed 140-point height;
- permanent queue-add, download/delete, transcript, and replay buttons;
- `applyDownloadDisplay`, `applyQueueDisplay`, and raw
  `downloadButtonHandler` behavior;
- row-tap playback and the played-episode UIKit action sheet;
- download/progress accessibility hosts;
- retired analysis-timeline hosts and hidden layout remnants;
- manual accessibility-child ordering;
- `EpisodeTableViewCellLayoutTesting` and its production test accessors.

Keep `EpisodeTableViewController` only for table ownership, feed updates,
refresh, scrolling, and hosting the shared SwiftUI row.

Replace the callback chain through `PodcastDetailView`, `EpisodeListView`, its
representable, and controller with shared presentation lookup plus
`EpisodeRowActions`. Remove obsolete callbacks including `onAddAndPrepare`,
direct raw-download callbacks, and prepare-before-play row activation.

### Remove the old Queue row and Downloads section

Delete:

- private `QueueEpisodeRow` and its status-color, progress, recovery-title,
  row-tap, and accessibility-hint logic;
- Queue's duplicate Play now menu action;
- `downloadsExpanded`;
- Queue Downloads markup and explanation;
- `DownloadSummaryCategory` and `DownloadsSummary`;
- downloaded-item candidate filtering, sorting, and summary construction from
  `QueuePresentationBuilder`;
- Queue presentation fields used only by Downloads.

`QueueEpisodePresentation` carries the shared row presentation instead of
requiring Queue to reinterpret raw availability. Replace Queue's per-action
closure list with `EpisodeRowActions` plus Queue-only move, remove-with-Undo,
and reorder operations.

### Remove implicit prepare-and-play

Play is ready-only, so delete the machinery that waits for preparation and
auto-plays later:

- `pendingQueueActivationEpisodeID`;
- `queueActivationGeneration`;
- `queueActivationTask`;
- `activateQueueEpisode`;
- `waitForQueueActivationReadiness`;
- `finishQueueActivationIfCurrent`;
- `invalidateQueueActivation`;
- `playReadyEpisodeNow`;
- `playQueuedEpisodeNow`;
- pending-activation Queue presentation/status fields and candidate IDs.

Replace it with a guarded ready-only Queue operation that revalidates readiness,
applies the existing interrupted-episode Queue mutation, and starts local
playback synchronously.

Delete `ImmediatePreparationOutcome` and `WarmPlanner.prepareImmediately` after
the final call-site audit confirms there is no non-row consumer.

Remove Library's implicit `startDownloadBeforePlay` branch. Move any still-needed
cloud-consent handling into explicit Download. Delete pending-download-before-
play state and callbacks that become unreferenced.

### Remove dead preparation UI and duplicate copy

Keep `QueueStatusButton`, which the mini-player uses, and move it to a clearly
named Queue-status source file if appropriate.

Delete unused `PreparationDetailView`, `isPreparationPresented`,
`openPreparation`, assignments that only dismiss the deleted sheet, and the
sheet's obsolete identifiers/tests.

Remove listener-facing copy duplication from:

- `PreparationStatusCopy`;
- `AnalysisJobStage.userLabel`;
- `AnalysisJobStage.listenerStatus`;
- `AnalysisJob.compactShelfStatus`.

Retain internal/debug descriptions only when still required. Production copy
comes from `EpisodeRowPresentationMapper` or a shared compact presentation
derived from it.

### Replace old accessibility contracts

Use stable episode-ID identifiers on both screens:

```text
episodeRow_{episodeID}
episodeStatus_{episodeID}
episodePrimary_{episodeID}
episodeProgress_{episodeID}
episodeMore_{episodeID}
```

Remove production and test dependencies on `downloadButton_*`,
`downloadProgress_*`, `queueAddButton_*`, duplicate Queue-specific row-action
identifiers, row taps that play, the old download/delete toggle, Add to Up Next
implying preparation, and Play initiating preparation.

### Cleanup completion audit

Repository-wide searches must return no production references to:

- deleted shelf types, callbacks, and identifiers;
- `EpisodeTableViewCell` or its testing seam;
- private `QueueEpisodeRow`;
- Queue Downloads summary/disclosure types;
- implicit prepare-and-play activation symbols;
- old wording such as **Play now** or **Add and prepare**;
- duplicate readiness copy or state-to-symbol mappings outside the shared
  presentation layer.

Historical ADRs may remain as history. Update active plans, current UX specs,
and code comments so none describe retired behavior as current.

## 7. Testing

### Pure model tests

Table-test resolver precedence for every state in section 2, including
unrequested/requested missing audio, measured and invalid progress, local files
with every job stage, cleaning disabled, stale jobs, foreground precedence,
safe failure classification, and retry-time wording.

Table-test that `EpisodeRowPresentationMapper` produces the exact status,
primary control, menu eligibility, symbol, semantic tint, and accessibility
copy. The same availability produces identical readiness presentation in
Library and Queue; only metadata and collection actions may differ.

### Planner and intent tests

- Automatic preparation selects exactly two eligible choices.
- Reorder, removal, setting changes, and playback advancement recompute them.
- Other queued episodes remain unrequested.
- Explicit Download survives relaunch and never adds to Up Next.
- Explicit and automatic ownership share one download/analyzer run.
- Cancelling one owner preserves work required by another.
- Remove Download suppression prevents immediate redownload.
- Suppression clears under the rules in section 4.
- Launch reconciliation is idempotent and repairs stale jobs safely.

### Action tests

- Download runs once and reaches verified readiness.
- Prepare reuses an existing file.
- Retry resumes the correct failed stage.
- Play is unavailable for every unready state and immediate when ready.
- A stale Play tap cannot stream or start preparation.
- Safe overrides appear only when their artifacts support the promise.
- Remove Download deletes audio without silently deleting transcripts unless an
  existing explicit all-local-data operation requests broader cleanup.

### Shared UI tests

- Library root has no readiness shelf or Queue shortcut.
- Queue contains Up Next only and no Downloads disclosure.
- Library and Queue show the same row, state copy, primary action, More behavior,
  and accessibility meaning for the same episode.
- Row-body taps do nothing; primary and More never trigger one another.
- Waiting and active states have one activity visualization, not duplicates.
- Download, Prepare, Retry, and Play transition correctly in place.
- Long text, narrow/transient zero width, light/dark appearance, VoiceOver, and
  every supported Dynamic Type size remain usable.
- Queue reorder, swipe removal, Undo, Move to Top, Mark as Played, auto-delete,
  mini-player clearance, and last-row scrolling remain intact.
- Library refresh, transcript backfill, cleaning summary, and long-list
  scrolling remain intact.

Rewrite or delete tests coupled only to `EpisodeTableViewCell`, the old download
button, Queue Downloads, or row-tap playback. Preserve still-relevant behavior
through mapper tests, hosted-row layout tests, and episode-ID-based UI tests.

Run focused resolver, mapper, planner, download, Library, Queue, playback,
accessibility, and hosted-layout suites, then the complete unit and UI suite.

## 8. Implementation order

1. Add resolver inputs, primary-control model, presentation mapper, and tests.
2. Add `EpisodePreparationPreferencesStore`; correct WarmPlanner selection to
   two automatic choices plus explicit owners.
3. Add shared action handlers and remove implicit prepare-and-play.
4. Build `EpisodeRowView` and migrate Queue Up Next.
5. Host the same row in Library and migrate transcript/played/cleaning actions.
6. Remove Library root shelf and Queue Downloads.
7. Perform every cleanup and repository-wide audit in section 6.
8. Run focused tests, full tests, and a manual device pass.

## 9. Definition of done

- Library is shows; Queue is Up Next.
- Both render one shared episode component.
- Play appears only for immediately playable episodes.
- Every other episode shows one truthful action or passive state.
- Download means the full path to readiness and never changes Queue membership.
- Only the next two eligible choices prepare automatically.
- Each row contains one readiness visualization.
- No old shelf, Queue Downloads, custom Library cell, private Queue row,
  implicit prepare-and-play path, duplicated readiness copy, or obsolete test
  contract remains in production code.
- Existing unrelated working-tree changes are preserved.
