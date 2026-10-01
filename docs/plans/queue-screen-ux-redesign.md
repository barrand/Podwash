# Shared Library + Queue Episode Readiness UI

Status: **implemented; automated verification complete; manual accessibility/device sign-off outstanding**.

Resumption baseline: **September 30, 2026 (`main` at `8658242`)**.

This document is the canonical plan for the next Library and Queue readiness
change. It supersedes the prior Ready to Play shelf, the Queue Downloads
disclosure, separate UIKit/SwiftUI episode rows, permanent Library accessory
buttons, and the implicit "prepare, then play" interaction.

Do not create a second implementation plan for this work. Update this file when
scope, sequencing, or completion evidence changes so there is one durable source
of truth.

## 0. Resumption baseline (historical)

This section records the September 30 starting state. The live implementation
status and verification evidence are in the execution ledger in section 8.

The first implementation pass completed only part of this plan. The shared
availability types, `EpisodeRowView`, explicit preparation preferences, and the
Queue's visible Up Next migration exist. The Library migration, old-path
deletion, ownership corrections, shared menu/action completion, and replacement
tests do not.

| Area | Repository state at resumption | Resumption status |
| --- | --- | --- |
| Availability resolver and readiness types | Present in `QueuePresentation.swift` | Partial: precedence tests and ownership inputs are incomplete |
| Row presentation mapper and `EpisodeRowView` | Present in `EpisodeRowView.swift` | Partial: copy/menu authority is still duplicated elsewhere |
| Queue Up Next | Renders `EpisodeRowView` | Partial: it still receives raw availability and uses incomplete menu wiring |
| Library show | Still renders custom `EpisodeTableViewCell` at fixed 140-point height | Not migrated |
| Preparation ownership | Durable explicit/suppressed sets exist | Partial: automatic-window, suppression, and launch reconciliation rules are incomplete |
| Ready-only actions | New handlers exist in `AppShellModel` | Partial: old prepare-then-play paths remain reachable |
| Library Ready to Play shelf | Removed from the visible Library root | Partial: dead shelf state and handlers remain |
| Queue Downloads | Removed from the visible Queue list | Partial: presentation data, summaries, tests, and mini-player copy remain |
| Tests | Some resolver and automatic-warm coverage exists | Incomplete: no shared-row contract coverage; legacy cell contracts dominate Library tests |

### Resumption rules

1. Preserve unrelated working-tree changes. At this baseline, uncommitted work
   overlaps preparation preferences and Queue/WarmPlanner tests; inspect and
   retain it before editing those files.
2. Complete behavior and pure tests before migrating Library UI. A shared visual
   component backed by conflicting action or ownership semantics is not done.
3. Keep the app buildable and focused tests green at every work-package gate.
   Temporary adapters may exist within a work package, but no compatibility
   path prohibited by section 6 may remain at the final cleanup gate.
4. Do not mark this plan implemented from screenshots or Queue-only success.
   Completion requires the repository searches, automated tests, and manual pass
   in sections 6–9.
5. Migrate affected tests and fixture composition in the package that changes
   their contract. Package E verifies the complete result; it is not a deferred
   repair stage for tests broken in A–D.

### Scope and preservation boundaries

This work completes the shared episode-row contract, its preparation ownership,
and the obsolete-path removal listed here. Retain the existing download engine,
serial planner, playback coordinator, persistence schema, and analysis pipeline
where they can satisfy the contract. Do not redesign discovery, CarPlay,
smart-autoplay ranking, or the audio-processing algorithms as part of this work.

Audit non-row consumers before deleting shared helpers: autoplay, cold-start
paused restore, media-services recovery, remote commands, and replay still need
their legitimate playback behavior. The ready-only rule applies to explicit row
Play and safe row overrides; replacing row activation must not accidentally
remove the separate autoplay/recovery workflows.

The older `docs/plans/played-episode-replay.md` remains useful background for
artifact retention and replay safety, but this plan supersedes its row-tap action
sheet and accessory layout. Section 3 below is authoritative for integrating
replay into the shared row.

Implementation reading order: sections 1–2 define the listener contract;
sections 3–5 define the interfaces, ownership, and integration rules; sections
6–7 define the deletion and test gates; section 8 is the execution ledger. When
implementation reveals an unresolved product choice, record it here rather than
silently encoding a new rule in a screen-specific callback.

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

Use an explicit button style inside the SwiftUI `List` and the UIKit-hosted row
so tapping one button cannot activate adjacent actions or the whole row. Remove
the More button's extra `onTapGesture`; opening the menu must not dispatch a
second business action. At accessibility text sizes, the same shared view may
put controls below the metadata to retain 44-point targets and readable status.
Verify that neither control is pushed outside the cell at narrow widths.

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

Normalize progress before formatting or drawing: finite values clamp to
`0...1`; missing, NaN, and infinite values use indeterminate progress. Keep retry
time formatting pure with an injected clock. Visible delayed rows refresh at
the displayed time unit's boundary and when the app foregrounds; a frozen retry
countdown must not depend on another download or settings event to update.

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

Resolve effective artifact requirements once and reuse them in the resolver,
planner, menu eligibility, and Play guard. A cloud consent flag alone does not
mean an ad result is required; current channel/global processing settings also
matter. Required completion follows this matrix:

| Effective requirements | Evidence needed in addition to installed local audio |
| --- | --- |
| No processing enabled | None |
| On-device processing only | Current local processing completed, including a valid empty result |
| Cloud ad checking enabled and consented | Current required local completion plus a completed ad result, including a valid empty ad result |
| Forced fresh replay active | Completion of that replay generation, even if ordinary processing is disabled |

Changing a playback action from mute to skip may re-project existing analysis;
it does not by itself justify another analyzer run. Enabling a previously
unfulfilled requirement or changing the normalized targets can revoke readiness.
Failure stage/category must be structured facts rather than inferred from raw
error text. Presentation may retain a safe checkpoint failure while ownership
is reconstructed, but a historical in-progress job is not an active operation.

Create one pure `EpisodeRowPresentationMapper`. It is the only source of visible
status copy, symbols, semantic tint, progress presentation, primary control,
safe failure copy, menu eligibility, and accessibility wording.

`EpisodeRowView` receives immutable presentation values and a separate action
bundle, equivalent to:

```swift
EpisodeRowView(
    episodeID: String,
    title: String,
    presentation: EpisodeRowPresentation,
    context: EpisodeRowContext,
    cleaningSummary: EpisodeCleaningSummary?,
    menu: EpisodeRowMenuPresentation,
    actions: EpisodeRowActions
)
```

It does not receive `DownloadManager`, `WarmPlanner`, `AnalysisJob`, settings,
or persistence stores.

`EpisodeRowPresentation` owns the primary slot and every readiness word, symbol,
tint, progress value, and accessibility value. `EpisodeReadinessStatus`,
`AnalysisJobStage`, Queue presentation, and playback chrome may expose internal
state but must not independently map it to competing listener-facing copy.
Pass `now` into time-sensitive mapping so retry wording is deterministic in
tests.

`EpisodeRowMenuPresentation` is also value-only. It declares applicable menu
items and their order without embedding closures or store references. It must
represent:

- ordered collection actions: Library add/remove, or Queue move to top followed
  by remove (both can be present);
- active-work action: cancel download, cancel preparation, retry now, or none;
- safe playback override: without ad skipping, original audio, or none;
- transcript visibility;
- played action: mark played, replay from beginning, or none;
- destructive local-audio removal visibility.

Use one shared menu builder for Library and Queue. Context controls only Queue
membership and reorder operations. It does not duplicate shared wording or
eligibility checks.

Cancel is available for explicit-owned queued/active download or preparation,
not for automatic-only work. Determine download versus preparation from the
verified-file/stage facts, not only the waiting readiness cases. Retry now is a
delayed-work action; a terminal failure already has primary Retry. Prefer Play
without ad skipping only when the actual failed component is cloud ads and
current local processing is complete. Otherwise offer Play original audio only
when a verified file exists and that explicit override is applicable. Recheck
the same conditions at execution; a stale open menu cannot make a weaker promise.

The mapper receives a resolved fact snapshot, not just a readiness enum. Include
episode identity, availability, explicit/automatic/replay/current owners,
verified local-processing completion, cloud failure category, transcript and
played state, current replay generation, Queue membership, and context. These
facts determine menu eligibility without stores in the view. Pass only facts
needed by each layer; the mapper must not perform filesystem or cache writes.

Keep display data and closures separate: an equatable `EpisodeRowSnapshot`
contains title, context, presentation, menu, and cleaning summary;
`EpisodeRowActions` contains the callbacks. A Library snapshot lookup cannot be
called "value-only" if it embeds actions or a service reference. Resolve actions
by episode ID at the composition boundary. Queue and Library must use the same
snapshot factory rather than two nearly identical lookup implementations.

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

`EpisodeRowActions` exposes these shared handlers plus transcript, played-state,
safe-override, and Queue-only move operations. Every handler re-resolves state
before mutating anything. Cancel and Remove Download are distinct: cancellation
releases explicit ownership without deleting a completed file or automatically
suppressing future preparation; Remove Download deletes verified local audio and
adds suppression when automatic ownership would otherwise reacquire it.

### Ready playback handoff

The new handler must do more than guard readiness and call the existing
`playEpisode`. That function currently permits remote URL fallback and calls
`PlaybackCoordinator.preparePlayback`, which can invoke analysis again.

Resolve a verified local URL and current prepared artifacts at the action
boundary. Reuse the existing session builder with an explicit prepared-playback
input that installs the cached interval schedule before requesting playback;
do not invoke the analyzer or acquire preparation ownership for a ready tap.
An empty, completed interval result is valid. Retain resume-position handling,
audio-session/remote-command binding, player chrome, and Queue interruption
behavior. Session configuration may complete asynchronously, but no preparation
wait, polling activation, or automatic later takeover is allowed. Revalidate
episode/session generation and current requirements after any awaited handoff.

Stage any awaited prepared-schedule setup before committing a replacement:
capture the action generation, validate/install the candidate local schedule,
revalidate requirements, commit the context-specific Queue mutation, and then
replace the active session/request Play. A newer selection, removed local file,
or changed requirement invalidates that staged candidate. Do not tear down the
current player at the start of an await and then discover the stale action.

Queue ready Play and safe overrides perform the same interrupted-episode Queue
mutation. If Queue persistence fails, leave the current playback session intact
and show a safe error; do not silently start the replacement after a failed
mutation. A repeated tap on the current episode resumes its existing ready
session without restarting it or resetting its position.

### Replay and consent integration

Played state does not create a second readiness mapper. Primary Download,
Prepare, and Retry still occupy the same slot. When an unready played episode
requires fresh replay preparation, these actions route through the existing
shell-owned replay confirmation and worker, preserving its warning before old
transcript/analysis replacement. Confirmation establishes replay ownership and
never changes another episode's playback, Queue membership, played flag, or
resume position. Active forced replay work overrides a general cache-ready or
cleaning-disabled result until that replay generation finishes.

For a ready played episode, primary Play and More's Replay from Beginning use
the same ready guard and reset the position to zero only when playback is
accepted. Retain the Ready to replay banner and one-time dismissal behavior.
The primary button on an already-current episode resumes normally; an explicit
Replay from Beginning menu action remains the deliberate position-reset action.
Delayed/failed replay uses the common state copy, Retry, and safe-override rules;
it never bypasses readiness through an old row action sheet.

Move first-use cloud disclosure into the shared explicit Download/Prepare
request, including played/replay requests. Retain a pending episode ID and
request kind in the shell, never a cell callback. Acceptance resumes exactly
one planner request; declining uses the supported local-only processing mode.
Neither response plays or adds to Up Next. Clear invalid pending requests on
unsubscribe/cancellation; re-resolve availability and requirements on resumption.
Repeated taps for the pending episode coalesce; another row action must not
silently overwrite the request for which a disclosure is already visible.
An automatic request must respect existing consent without presenting a
disclosure unexpectedly. Test acceptance and decline from both screens.

## 4. Preparation ownership

Keep the existing serial `WarmPlanner`; change its request inputs rather than
building another preparation engine.

### Automatic readiness window

**Keep episodes ready automatically** prepares only the first two eligible
choices, matching the setting's existing listener-facing promise.

- Build one ordered automatic-choice set with a maximum of two IDs. Queue order
  fills it first; predictions fill only unused slots.
- Queue membership alone is not an owner. A queued episode owns automatic work
  only while its ID is in that exact two-choice set.
- Predictions fill unused slots only when existing smart-autoplay rules permit.
- An automatic choice waiting for the worker shows Waiting to download and no
  Download button because work is already requested.
- Other queued episodes without local audio remain Not downloaded with Download;
  downloaded episodes keep their truthful ready/not-prepared status.
- With the setting off, Queue episodes remain idle unless another explicit
  owner requires them.
- Reordering recomputes the automatic window.
- Work leaving the window stops when automatic preparation was its only owner.
- Completed local audio remains; resumable partial-transfer data may remain
  internal.

Explicit Download/Prepare intent and replay/current-playback requirements are
separate owners and do not change how the next two choices are selected. An
episode may be both explicit and automatic and is prepared once; explicit work
outside the automatic window may increase total owned work beyond two. The
serial worker still permits only one active download/analyzer run. Presentation
sets `hasActiveWorkOwner` from the union of these computed owner sets—not from
all Queue IDs and not merely
from the presence of a stale durable job.

Do not cap the saved Queue or the complete autoplay order when capping
preparation. `UpcomingSelectionPolicy` currently returns all manual entries;
introduce an explicit bounded preparation-window result alongside the full
ordered candidates. Skip missing catalog IDs, duplicates, the current episode,
and played episodes before selecting the next two. Ready episodes still occupy
their next-choice slots: do not keep preparing later episodes because the first
two are already ready. Predictions must obey smart-autoplay/binge eligibility
and the listener's settings.

Compute the unsuppressed **base window** first, then subtract suppression to
obtain automatic owners. A suppressed episode retains its base-window position;
do not fill its slot from the third Queue item. Clear its suppression only when
it leaves the base window or the listener explicitly requests Download/Prepare.
Filtering it out must not itself make it appear to have left the window. This
prevents a suppress/clear/redownload loop and keeps preparation aligned with
the actual next two listening choices.

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
- Suppression clears when the episode leaves the base window or the listener
  explicitly taps Download/Prepare; filtering suppression never changes that
  base window.
- Queue membership does not create or erase explicit Download intent.
- Cancelling one owner stops work only when no other owner remains.

Planner priority is replay/current playback requirements, explicit Download or
Prepare requests, then the automatic next-two window (Queue choices before
prediction fill). Predictions do not create an additional ownership tier outside
that window. All owners share one download and one analyzer run.

On launch, compute the same owner sets before reconciling jobs. Reconciliation
receives replay/current, durable explicit, and current automatic-choice IDs;
passing every Queue ID is incorrect. A stale ready job without a verified file
becomes queued only when one of those real owners still requires it, otherwise
it is removed. Reconciliation and repeated scheduling must be idempotent.

### Worker scheduling and persistence invariants

- Keep the latest complete owner snapshot in the planner. An explicit request,
  retry, or cancel changes one owner and recomputes work from that snapshot;
  it must not call `reaim(requests: [])` and drop the other automatic/replay work.
- Schedule explicit IDs deterministically (stable episode-ID order is sufficient
  with the existing Set payload). Do not restart work because Set iteration
  produced a different order. Persist intent before acknowledging a request and
  clear it only after verified readiness or an explicit terminating operation.
- Limit work using the current automatic window, not the lifetime size of
  `warmedEpisodeIDs`. Previously prepared files do not block preparing a new
  next choice after playback advances or Queue order changes.
- Retry timers enqueue work into the same serial worker. They must never call
  `warmOne` from a second Task while the main worker analyzes another episode.
  Track and cancel timers; `quiesce()` awaits all active work, and generation
  checks prevent late writes or retries after cancellation, removal, or replay.
- Classify download, local processing, and cloud-ad failures separately. A
  network download failure must not become "Ad check delayed". Retry preserves
  valid earlier-stage artifacts and backoff history; cancellation is not failure.
- Durable jobs that claim downloading/preparing/checking after a process exit
  do not prove active work. Reconcile them to queued work with an owner or to an
  idle/removed checkpoint without one. Resume delayed retries using persisted
  retry deadlines rather than immediately restarting them on every refresh.
- Settings changes recompute artifact requirements and ownership. Reuse the
  existing cache fingerprint/provenance checks. After installing replacement
  audio, old timestamps must not be considered valid merely because episode ID
  and target words match; retain historical transcript access separately from
  playback readiness and invalidate/rebuild playback artifacts when required.
- Remove explicit/suppressed IDs on unsubscribe and all-local-data cleanup,
  prune missing catalog IDs, and isolate preference storage per test fixture.

### Collection and destructive-action boundaries

| Operation | Queue effect | Ownership/artifact effect |
| --- | --- | --- |
| Add to Up Next | Add once | Recompute automatic window; no explicit Download intent |
| Remove from Up Next / Clear Up Next | Remove membership | Release only resulting automatic owners; retain completed audio, transcript, and explicit/replay work |
| Cancel Download / Preparation | None | Release explicit request; retain completed files and any work still owned elsewhere |
| Remove Download | None | Release explicit intent, suppress current automatic owner, cancel/settle target writes, delete audio/partial transfer data only |
| Mark as Played | Remove target from Up Next | Update history; postpone configured audio deletion until Undo expires |
| Unsubscribe / explicit all-local-data cleanup | Remove affected membership | Retire all affected owners, settle writes, then delete requested artifacts |

The current `removeFromUpNext` and `clearUpNext` delete unfinished episodes'
local data. Replace that behavior; downloaded-but-unprepared audio is still a
completed download. Undo restores the collection/history change without needing
to reconstruct deleted files. Cancellation need not delete resumable transfer
data that an existing owner may reuse.

Before audio removal or replay artifact replacement, await the target's worker
and download settlement so late callbacks cannot reinstall deleted files. Do
not discard another episode's owners while settling the target. If the current
playback/replay operation protects the file, omit Remove Download and recheck
that guard on a stale menu action rather than deleting audio underneath it.
Recompute and publish state after the operation completes, including a safe
error if removal fails; do not report success solely because intent was cleared.

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

`PodcastDetailView` supplies the table a row snapshot provider and a
single revision/generation input. For an episode ID, the provider returns the
same `EpisodeRowSnapshot` used by Queue, with Library context metadata. Supply
the separate action lookup alongside it. `EpisodeTableViewController` may retain
table ownership and episode-ID/index-path lookup, but it must not receive or
interpret `DownloadManager`, `WarmPlanner`, Queue storage, analysis jobs, or
played/transcript rules after migration.

Each reusable cell hosts `EpisodeRowView` through `UIHostingConfiguration`.
Configuration updates replace the value snapshot; they do not stack hosting
controllers, gestures, observers, or accessibility elements. Use automatic row
height and verify the transient zero-width pass rather than retaining the old
140-point workaround.

### Observation and fixture composition

The shell owns service subscriptions and publishes one row-data revision plus
affected episode IDs where available. The shared snapshot factory consumes
that revision so Queue and Library observe the same inputs. Download progress
must invalidate Library as well as Queue; currently the shell's download handler
only refreshes Queue presentation. Include planner stages, replay generation,
settings/cleaning requirements, played/Queue changes, transcript backfill, and
foreground/file reconciliation in the same refresh contract.

Reconfigure visible cells for state-only updates without reloading the whole
table on every progress callback. Preserve scrolling position and VoiceOver
focus; structural feed changes reconcile stable episode IDs. Bind action
closures to IDs, never captured index paths that can point at another episode
after refresh/reordering. A reused cell must replace its snapshot and actions
without retaining its previous episode. Remove observers/handlers with their
owner; do not overwrite single global `onStateChanged` callbacks from the table.

`DownloadManager.localFileURL` currently migrates files and can notify state
changes. Perform that reconciliation before building snapshots, or use a
nonmutating verified-file snapshot, to avoid notification/revision recursion
during SwiftUI rendering. Verification means a readable installed local file;
partial transfers and a persisted downloaded flag do not qualify.

`RootView` also constructs `PodcastDetailView` for exclusive feed/analysis/
download fixtures without `AppShellModel`. Migrate that composition in Package C
using the shared mapper/view with fixture dependencies; do not preserve the
legacy cell for fixtures. Keep header cleaning controls and their observation
working even though row-only `AnalysisUIViewModel` plumbing is removed.

### Queue

Queue contains one Up Next section only. Remove the Downloads disclosure and
all global downloaded-episode summary/filtering behavior.

Preserve saved order, reorder mode, Move to Top, swipe removal, five-second
Undo, Mark as Played, auto-delete-after-played, mini-player clearance, and the
empty state.

The mini-player Queue status button continues to open Queue. It consumes the
same availability presentation but does not render `EpisodeRowView`.

Its fallback copy describes Up Next only: **Empty**, **1 Up Next**, or
**N Up Next**. When useful active work exists for an Up Next episode, it may show
the mapper-derived compact status and title. It must not count or summarize a
global Downloads collection after that collection is removed.

Use shell-owned Undo state for shared removal/played actions so Library and
Queue retain the same five-second behavior across navigation. Track each
mutation's identity and commit once. Expiry of Mark as Played may delete audio
only if the episode is still played and no new explicit/replay/current-playback
owner protects it. Undo or an intervening replay/add/reorder must not be
overwritten by restoring an obsolete whole-Queue snapshot; restore the affected
membership/history relative to the captured neighbors and preserve intervening
changes. Clear Up Next Undo likewise merges restored IDs without duplicating or
discarding newly added entries. Test tab navigation while Undo is pending.

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

Delete `PodcastDetailView.upNextSection`, its unused Queue row markup, and the
old `onPlayQueuedEpisode` callback after migrating every constructor, including
`RootView` fixtures. Keep unrelated header cleaning/settings inputs that still
have a real consumer.

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
applies the existing interrupted-episode Queue mutation, and requests local
playback using already-prepared artifacts. Async engine/schedule installation is
permitted as described in section 3; a preparation wait or later takeover task
is not.

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

Keep a stable episode-scoped cleaning-summary identifier and stable menu-item
identifiers such as `episodeMenu_{action}_{episodeID}` for transcript, cancel,
membership, replay, and removal assertions. Use the same action tokens on both
screens; item availability varies, identity does not. VoiceOver should encounter
title/metadata/status once, then primary and More as independent controls.
Passive clock/progress labels must not duplicate the full status announcement.
Reordering hides primary/More from the accessibility tree as well as visually.

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

Run searches separately against production, tests, and documentation: this plan
deliberately names deleted symbols, so a repository-wide raw match count cannot
be the completion metric. For example, the following production search must
produce no matches (exit status 1 from `rg` means no matches):

```sh
rg -n 'ReadyToPlayChoice|readyToPlayChoices|preparationShelfStatus|playReadyChoice|EpisodeTableViewCell|EpisodePlayStackView|QueueEpisodeRow|DownloadSummaryCategory|DownloadsSummary|downloadsExpanded|pendingQueueActivationEpisodeID|queueActivationGeneration|queueActivationTask|activateQueueEpisode|waitForQueueActivationReadiness|completeQueueActivation|finishQueueActivationIfCurrent|invalidateQueueActivation|playReadyEpisodeNow|playQueuedEpisodeNow|ImmediatePreparationOutcome|prepareImmediately|startDownloadBeforePlay|pendingDownloadForPlayEpisodeID|PreparationDetailView|isPreparationPresented|openPreparation|PreparationStatusCopy|compactShelfStatus|onAddAndPrepare|addAndPrepare|onPlayQueuedEpisode|downloadButton_|downloadProgress_|queueAddButton_|episodeCell_|Add and prepare|Play now' PodWash/PodWash --glob '*.swift'
```

Also inspect actual call sites for `userLabel`, `listenerStatus`,
`downloadsSummary`, `presentation.downloads`, and duplicated readiness switch
statements; generic names and conceptual duplicates need review, not blind
deletion. Repeat legacy-identifier searches against `PodWashTests` and
`PodWashUITests` and require no live test dependency on the removed behavior.

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

Test menu membership and ordering independently of UI rendering, including both
Queue collection actions at once. Safe overrides require verified artifacts and
the matching failure category at display and execution time; merely having a
file or being in `.adCheckDelayed` is insufficient. Include completed empty
local-processing records, disabled cleaning/cloud requirements, changed target
sets, invalid progress, and deterministic past/future retry times.

### Planner and intent tests

- Automatic preparation selects up to two eligible choices, exactly two when
  enough candidates exist, and zero when the setting is off.
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

### Required adversarial scenarios

| Scenario | Required result |
| --- | --- |
| Queue `[A, B, C, D]`, automatic setting on/off | On: only A/B automatic owners; off: no automatic owners; Queue order unchanged |
| Remove A's download while A/B are next | A remains suppressed, B remains owned, C is not promoted merely to replace suppression |
| Explicit Download C while A is preparing | C gains explicit priority; A/B ownership survives; analyzer concurrency remains one |
| Cancel explicit A while A also has an automatic/replay owner | Release explicit ownership only; required work survives |
| B's retry deadline arrives while C is analyzing | Enqueue B; never start concurrent analysis; cancelled B never retries later |
| Remove/Clear an unready queued episode with explicit work/local audio | Retain completed audio/transcript and explicit/replay work; Undo changes membership only |
| Cached ready row becomes stale before Play/after an awaited handoff | Preserve current playback and Queue; refresh state; no stream or preparation is started |
| Active forced replay with cleaning off and an old cache | Show active replay state, never premature Play; accepted replay playback resets position to zero; preparation confirmation does not; no autoplay on completion |
| Feed refresh inserts/reorders rows while a menu is open | Action still targets the original episode ID; a deleted episode safely rejects the action |
| Restart with explicit intent, delayed/stale jobs, and suppression | Reconstruct real owners once; retain backoff; no whole-Queue preparation or suppression loop |
| Undo expires after replay or new Queue changes | Commit once, preserve new state/owners, never delete newly protected audio |

Use controlled clocks and cancellation-aware spies for these cases. Measure
maximum active analyzer calls across normal work, retries, replay, and any
legitimate foreground consumer. Avoid timing sleeps as the main correctness
signal. Extend existing fixture seams rather than depending on live feeds or
cloud calls.

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

### Legacy test migration inventory

At the resumption baseline, these tests directly depend on the old cell type or
index-based row/accessory identifiers and must be rewritten or deleted:

- unit/layout: `EpisodeDownloadAffordanceTests`,
  `EpisodeListTimelineRetirementTests`, and
  `EpisodeTableViewCellLayoutTests`;
- UI: `AnalysisProgressUITests`, `AnalysisTimelineUITests`,
  `CleaningSummaryUITests`, `CloudConsentShellUITests`, `DownloadUITests`,
  `EpisodeListUITests`, `LibraryUITests`, `NowPlayingSessionUITests`,
  `SmartAutoplayUITests`, and `TranscriptUITests`.

Also audit `AnalysisJobTests`, `NowPlayingSessionTests`,
`ProductionAnalysisWiringTests`, `PlaybackReadinessTests`, and Queue store tests
for removed copy, old play wrappers, raw-download consent handling, and Undo
snapshot assumptions. New test suites may use names such as
`EpisodeRowPresentationTests`, `EpisodeRowActionTests`, and
`HostedEpisodeRowLayoutTests`; create each with the corresponding package.

Do not mechanically rename old identifiers when their interaction contract has
changed. Preserve the listener behavior being tested, then target stable episode
IDs and the new `episodeRow_`, `episodeStatus_`, `episodePrimary_`,
`episodeProgress_`, and `episodeMore_` surfaces. Add at least one fixture-driven
test that presents the same episode state in Library and Queue and compares its
status, primary action, menu eligibility, and accessibility meaning.

Run focused resolver, mapper, planner, download, Library, Queue, playback,
accessibility, and hosted-layout suites, then the complete unit and UI suite.

## 8. Resumption execution plan

Implement the remaining work in the following packages. A package is complete
only when its exit gate passes; do not defer its failing tests to a later UI
package.

### Package A — behavior and ownership foundation

1. Preserve and account for existing uncommitted changes in preparation and
   test files.
2. Table-test every resolver state and failure classification.
3. Correct automatic selection to exactly the first two eligible Queue/predicted
   choices while keeping explicit and replay/current owners independent.
4. Make active-owner presentation consume the computed owner union rather than
   all Queue IDs.
5. Complete durable explicit intent, automatic suppression clearing, launch
   reconstruction, cancellation, and idempotent reconciliation.
6. Route retry deadlines through the worker; test cancellation/late-write
   settlement and update existing planner/Queue model tests in this package.

**Exit gate:** planner/intent/resolver tests cover long manual Queues, setting
off, reorder/removal, prediction fill, explicit relaunch, shared ownership,
suppression entry/exit, stale jobs, and maximum analyzer concurrency one.
Existing owned work survives an explicit request/retry/cancel; the next window
can prepare after earlier episodes were already warmed.

### Package B — shared presentation, menu, and actions

1. Make `EpisodeRowPresentationMapper` the sole readiness copy/symbol/tint/
   progress/accessibility authority and add exhaustive mapper tests.
2. Add the value-only menu presentation and one shared menu builder.
3. Complete `EpisodeRowActions`; wire Queue to the shared retry, cancel,
   transcript, played, safe-override, and removal handlers.
4. Change Queue row presentation to carry the completed shared row/menu values,
   not raw availability that the view reinterprets.
5. Add the prepared-local session handoff, replay integration, and shared
   explicit-request consent flow. Wire the new Queue controls exclusively to
   them; adapt Queue/action/consent/session tests alongside the change.
6. Correct collection-removal artifact retention and share guarded Undo state
   through the shell. Cover intervening collection/history changes.

**Exit gate:** action tests prove stale Play is a no-op, unready states never
play or stream through the new row controls, ready playback invokes no analyzer,
repeated taps are idempotent, cancel differs from removal, safe overrides are
artifact-gated, and Queue uses no second readiness mapper. Legacy Library
callers are explicitly inventoried for migration in Package C; do not delete
their dependencies prematurely and leave the app uncompilable.

### Package C — Library migration

1. Introduce the Library row snapshot provider and shared action wiring through
   `PodcastDetailView` and `EpisodeListView`.
2. Host `EpisodeRowView` with `UIHostingConfiguration` in the retained table
   controller using self-sizing rows.
3. Refresh/reconfigure by episode ID for download, preparation, analysis,
   cleaning, Queue, transcript, played, and settings changes.
4. Migrate Library More actions and remove row-body playback.
5. Delete the custom `EpisodeTableViewCell`, all manual constraints/accessory
   controls, refresh helpers, accessibility ordering, fixed height, and testing
   seam in the same package.
6. Migrate `RootView` exclusive fixtures and all affected Library UI/layout
   tests, including played replay and consent. Update smoke-test filters and
   active verification mappings if test names change.
7. Replace the final legacy row playback callers; delete pending Queue
   activation state/tasks, `prepareImmediately`, old Queue play wrappers, and
   Library's download-before-play branch after auditing non-row consumers.

**Exit gate:** hosted-row layout tests and focused Library UI tests pass for
zero/narrow/phone widths, Dynamic Type, transcript backfill, refresh, long-list
last-row interaction, mini-player clearance, and all primary state transitions.
No fixture or test constructor still requires the custom cell or implicit row
activation machinery. Cross-surface parity tests pass in this package.

### Package D — dead-path and contract cleanup

1. Delete dead Library Ready to Play types, computed properties, handlers, and
   comments.
2. Delete Queue Downloads fields, summaries, filtering/sorting, tests, and
   mini-player references; retain download storage APIs used outside Queue.
3. Delete `PreparationDetailView` and obsolete presentation state.
4. Remove duplicate listener copy from `AnalysisJobStage`,
   `PreparationStatusCopy`, and compact shelf helpers after migrating legitimate
   playback consumers to mapper-derived compact presentation.
5. Update active UX documentation and comments; historical ADRs may remain.
6. Run every repository search in section 6 and require zero production hits.

**Exit gate:** the project builds with no compatibility implementation or test
seam prohibited by section 6, and Queue fallback copy describes Up Next only.

### Package E — final regression and release verification

1. Confirm the legacy test inventory was migrated in Packages A–D, with each
   still-relevant listener behavior retained. Close any missing coverage before
   calling this a verification-only package.
2. Complete the cross-surface/accessibility regression matrix and cleanup audit.
3. Run focused resolver, mapper, planner, download, Library, Queue, playback,
   transcript, accessibility, and hosted-layout suites.
4. Run the complete unit/UI verification command.
5. Perform a manual simulator/device pass in light/dark appearance, VoiceOver,
   an accessibility Dynamic Type size, long Library and Queue lists, and each
   readiness/failure state.

**Exit gate:** section 9 is demonstrably true, the plan status changes to
**implemented and verified**, and the completing commit records the automated
and manual evidence.

### Change map and verification commands

| Package | Principal files/call sites |
| --- | --- |
| A | `UpcomingSelectionPolicy.swift`, `WarmPlanner.swift`, `EpisodePreparationPreferencesStore.swift`, `AppShellModel` ownership/reconciliation, `QueuePresentation.swift` resolver |
| B | `EpisodeRowView.swift`, shared snapshot/menu mapping, `AppShellModel` actions/prepared-session/consent/Undo, `AppShellView.queueTab`, `QueueTabView.swift` |
| C | `PodcastDetailView.swift`, `EpisodeListView.swift`, `AppShellView.LibraryPodcastDetailView`, `RootView` fixtures, hosted-row and affected Library UI tests |
| D | dead shell state, `QueuePresentation.swift` Downloads types, `PreparationShelfView.swift`, `AnalysisJob.swift`, active specs/test filters |
| E | shared fixture matrix, final source/test audits, verification results and manual evidence |

Use the repository's sanctioned `scripts/verify.sh`, from the repository root.
Use focused filters while developing (add newly created suites to the actual
command rather than copying nonexistent test names):

```sh
VERIFY_TIER=2 scripts/verify.sh \
  -only-testing:PodWashTests/QueuePresentationTests \
  -only-testing:PodWashTests/WarmPlannerTests
```

Each later package adds its mapper/action/hosted/UI filters. Smoke filters in
`scripts/verify.sh` must exercise explicit ready Play after the Library contract
changes. For the final gate, run the unfiltered suite:

```sh
scripts/verify.sh
```

Record the `VERIFY RESULT` line and generated result directory. Filtered green
runs and screenshots alone do not establish completion. Final verification
requires zero failures and zero skips; identify any pre-existing failure with
evidence and leave the plan partially verified until the required gate passes.

Maintain a small execution ledger below; advance it only with an exit-gate
result. Start with the current package and do not replace the product contract
with implementation notes.

| Package | Status | Commit/change evidence | Verification evidence |
| --- | --- | --- | --- |
| A | Implemented; automated gate passed | Current-window selection; durable explicit owners; suppression/reconciliation; serial analyzer and retry worker; cancellation retains completed audio | Complete unit/UI gate passed: 357/357, zero failures/skips (`verify-20261001-091744-35266`) |
| B | Implemented; automated gate passed | Shared snapshot/mapper/menu; ready-only staged local Play; consent, replay confirmation, shell Undo and retention | Complete unit/UI gate passed; playback and full-player transcript regressions specifically exercised |
| C | Implemented; automated gate passed | Library hosts `SharedEpisodeRow` via self-sizing `UIHostingConfiguration`; immutable snapshots update only changed visible cells; fixture composition migrated | Complete unit/UI gate passed, including shared Library/Queue row parity, long-list and consent cases |
| D | Implemented; source audit passed | Legacy cell, permanent accessories, shelf state, Downloads presentation and prepare-then-play row paths removed; historical UX specs explicitly superseded | Latest source builds; prohibited production symbols have zero hits; exactly two production `SharedEpisodeRow` call sites. Historical spec notices retained, old cleaning-toggle identifier appears only in a negative absence test. Slice ID audit passed (34 stories) |
| E | Automated verification passed; manual sign-off pending | Migrated unit/UI fixture contracts; long-list, playback, transcript and consent regressions | Final unfiltered gate: 357/357, zero failures/skips (`verify-20261001-091744-35266`, 1,211 s). Focused final regression: 13/13, zero failures/skips (`verify-20261001-084706-28630`) |

Implementation notes (October 1, 2026): the complete unit/UI gate passed after
the final fixes. Focused green runs remain diagnostic evidence; the final
unfiltered result above is the automated ship gate. Manual VoiceOver/device and
full appearance/state-matrix sign-off remain unverified; the app currently
forces dark appearance. No completing commit has been made.

Latest focused verification command (67 passed, zero failures/skips):

```sh
PODWASH_SIM='PodWash Shared Row QA 20261001' VERIFY_TIER=2 scripts/verify.sh \
  -only-testing:PodWashTests/EpisodeRowActionTests \
  -only-testing:PodWashTests/EpisodeDownloadAffordanceTests \
  -only-testing:PodWashTests/QueuePresentationTests \
  -only-testing:PodWashTests/WarmPlannerTests \
  -only-testing:PodWashTests/SerialEpisodeAnalyzerTests \
  -only-testing:PodWashTests/SharedEpisodeRowLayoutTests \
  -only-testing:PodWashTests/HTMLDescriptionTextTests \
  -only-testing:PodWashTests/DownloadManagerTests \
  -only-testing:PodWashUITests/CloudConsentShellUITests \
  -only-testing:PodWashUITests/AnalysisTimelineUITests \
  -only-testing:PodWashUITests/DownloadUITests \
  -only-testing:PodWashUITests/LibraryUITests/testLibraryAndQueueShareRowAndMenuWithoutTapToPlay
```

Result: `VERIFY RESULT: exit=0 total=67 passed=67 failed=0 skipped=0 filtered=1
bundle=build/test-results/verify-20261001-011858-72294/result.xcresult tier=2
class=tests elapsed_s=153`.

Playback recovery and final automated verification: the prior unfiltered run
`verify-20261001-010735-68895` and isolated-device playback run
`verify-20261001-011417-70896` were interrupted after audio-service failures.
The latest-source unit-only rerun `verify-20261001-012210-73280` reproduced
the same skip/overlay playback failures and was also interrupted; it is not
a passing unit-suite result.
AVPlayer reported requested playback while its playhead stayed at zero; logs
included `AQMEIO` start timeouts, `MEDeviceStreamClient` failed starts and
`CA_UISoundClient` status `-66681`. The same failure reproduced on a freshly
created simulator, so leftover app state is not sufficient to explain it. This
is evidence of an environment-level audio start problem, not proof that the
new playback path is regression-free. Playback assertions were not weakened.
With user approval, simulator services were restarted and the issue cleared on
a clean disposable simulator. The playback, full-player transcript and shared
row focused regression (`verify-20261001-084706-28630`) passed 13/13, followed
by the unfiltered gate above. A Queue session-relaunch assertion was migrated
from its retired Queue-only identifier to the shared `episodeRow_{episodeID}`
contract; its focused regression passed before the final unfiltered rerun.

## 9. Definition of done

- Library shows subscriptions; Queue shows Up Next.
- Both render one shared episode component.
- Play appears only for immediately playable episodes.
- Every other episode shows one truthful action or passive state.
- Download means the full path to readiness and never changes Queue membership.
- Only the next two eligible choices prepare automatically.
- Queue membership outside that two-choice window remains idle unless an
  explicit, replay, or current-playback owner requires work.
- Cancel, Remove Download, and Remove from Up Next have distinct effects and
  never erase another owner's requirement.
- Each row contains one readiness visualization.
- Library and Queue use the same readiness mapper, shared menu builder, and
  action handlers; only metadata and collection-management actions differ.
- No old shelf, Queue Downloads, custom Library cell, private Queue row,
  implicit prepare-and-play path, duplicated readiness copy, or obsolete test
  contract remains in production code.
- Focused and full automated verification pass, and the manual accessibility/
  appearance/device matrix is recorded in this file or the completing commit.
- Existing unrelated working-tree changes are preserved.

### Completion record

Leave this section blank until all exit gates pass. At completion, record:

- completing commit;
- focused test commands and results;
- full verification command and result;
- manual devices/simulators, appearances, Dynamic Type, and VoiceOver result;
- cleanup-search result and any intentionally retained historical-document hits.
