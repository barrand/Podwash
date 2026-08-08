# Queue, preparation, and readiness plan

## Summary

Make Queue a permanent third tab with a persistent mini-player. It is the one place to manage playback order and see preparation state.

The screen has two core sections:

- **Up Next** — listener-controlled order; every item is being prepared or already ready.
- **Ready to Play** — downloaded, prepared episodes available for smart autoplay or immediate play.

The mini-player keeps its compact Queue line. It reports the preparation task most likely to affect listening next; the Queue tab shows the complete status for each Up Next item.

## Listener behavior

### Add and prepare

Replace the episode-list Download button with **Add & Prepare**.

- It adds the episode to the end of Up Next and queues its download plus clean-playback preparation.
- It is an explicit listener action, so it works even when automatic downloads are off or the listener is on cellular.
- Its state changes to **In Up Next**. A downloaded, prepared episode outside the queue instead offers **Add to Up Next**.
- Remove the duplicate inline Up Next list from podcast-detail screens.

This supports a long-drive workflow: a listener can add twelve episodes, all twelve retain their selected order, and all twelve are processed serially rather than being discarded by an automatic warm-cache cap.

### Up Next

Each row always shows a dedicated six-dot drag handle. The `•••` control is a distinct More menu.

- Dragging persists manual order immediately.
- Tapping a row, or choosing **Play now**, starts that episode. The interrupted episode becomes first in Up Next and the other queued episodes preserve their relative order. For current `X` and queue `[A, B, C]`, playing `B` persists `[X, A, C]`.
- More actions are **Play now**, **Remove from Up Next**, and **Remove download**.
- Removing from Up Next retains a completed download (which becomes eligible for Ready to Play), but cancels unfinished download/preparation work. A listener should never keep spending bandwidth on something they removed.
- Removing a download cancels/removes local work, its queue entry, its durable job, transcript, derived cache, and analysis artifact.
- Put **Clear Up Next** in the section overflow rather than beside the title. It retains completed local downloads, cancels unfinished work, and offers Undo for five seconds; Undo restores the prior order and requeues any canceled work.

### Ready to Play

Ready to Play contains only episodes with both a local audio file and a usable completed preparation result. It is ordered by the smart-autoplay preference, then most recently prepared.

- Tapping a row or choosing **Play now** uses the same immediate-playback behavior as Up Next.
- More actions are **Play now**, **Add to Up Next**, and **Remove download**.
- Smart autoplay prefers Ready to Play episodes but never reorders listener-selected Up Next items to favor readiness.

### Friendly preparation status

Use listener-facing stages; do not show technical implementation names or fabricated analysis percentages.

| Internal state | Listener copy |
| --- | --- |
| `queued` | Waiting to prepare |
| `downloading` | Downloading · 42% |
| `transcribing` | Preparing clean playback |
| `checkingAds` | Checking for ads |
| `ready` | Ready (or `Ready to play · ad checks off` when applicable) |
| `adCheckDelayed` | Ad check delayed · retrying automatically |
| `needsAttention` | Needs attention |

Show a determinate progress bar only for download work. Error rows expose **Retry now** and **Play with ads**.

### Mini-player Queue status

Retain the compact Queue line, but navigate to the Queue tab rather than opening a sheet. Choose its one displayed status in this order:

1. Preparation/recovery of the current episode when it blocks playback.
2. The first unfinished Up Next episode.
3. The first unfinished automatic candidate.
4. A summary such as `3 Up Next · 2 ready`.

Examples: `Downloading A Question of Trust · 42%`, `Preparing clean playback · The Daily`, and `Checking for ads · Revisionist History`.

The mini-player remains visible in Library, Queue, Discover, Settings, and transcript flows. The full player is the sole screen that replaces it.

### Automatic preparation and cellular data

- Explicit Add & Prepare work is prioritized and unbounded.
- Automatic work maintains at least two ready episodes beyond the active episode, considering no more than four ranked candidates while work is in progress.
- Automatic work follows the existing auto-download setting.
- The default connection policy is any connection. On the first automatic download over cellular, ask the listener to either continue on cellular or change to Wi-Fi only. Persist the choice and never block explicit Add & Prepare.

## Technical design

### Navigation and presentation

- Add `.queue` to the root `TabView` selection and render `QueueTabView` there.
- Replace `PreparationDetailView` as the user-facing Queue destination. `QueueStatusButton` stays, receives structured status data, and selects the Queue tab on tap.
- Preserve the transparent/non-interactive mini-player tab-bar reservation. The card ends above UIKit tab controls and never paints over their icons or labels.

### Queue domain, data, and public operations

Introduce a `QueueController` as the sole owner of queue decisions. `AppShellModel` binds it to SwiftUI and the player; `QueueCoordinator` only asks it whether the next result is `.play`, `.waitForPreparation`, or `.none`. This removes the current callback split between manual and smart selection and ensures the UI and autoplay use identical ordering rules.

Keep `QueueStore` as the durable manual-order source and retain `selectForImmediatePlayback(_:replacingCurrentEpisodeID:)`.

Create a shared presentation value in `AppShellModel`, used by Queue and the mini-player:

```swift
struct QueuePresentation {
    let upNext: [QueueEpisodePresentation]
    let readyToPlay: [QueueEpisodePresentation]
    let preparingCount: Int
    let activeStatus: QueueStatusPresentation?
}
```

`QueueEpisodePresentation` joins the persisted queue ID, podcast metadata, `AnalysisJob`, and local-download state. Manual Up Next order is authoritative: do not use `AnalysisJob.orderedForQueueDisplay` for this section. When its first item is not ready, autoplay waits for it; it must never skip ahead to a later ready manual item.

Add these model operations:

```swift
addAndPrepare(episodeID:)
moveQueuedEpisode(_:to:)
playQueuedEpisodeNow(_:)
removeFromUpNext(_:)
clearUpNext() / restoreUpNext(_:)
removeDownloadAndPreparation(_:)
addReadyEpisodeToUpNext(_:)
```

`removeDownloadAndPreparation` must remove queue state, cancel work where possible, remove the durable job, and delegate file/cache deletion to `DownloadManager.deleteDownload`.

### Planner, durable job lifecycle, and readiness

Refactor `WarmPlanner` to process prioritized requests:

```swift
enum PreparationPriority {
    case userRequested
    case automatic
}
```

- Process user-requested queue items in persisted order before automatic candidates.
- Do not apply `peekCount` or `warmCap` to explicit requests. Apply the automatic four-candidate window and warm cap only to automatic work.
- Keep the current serial worker; it prevents download/analysis contention while ensuring a twelve-episode manual queue eventually completes.
- Extend `AnalysisJob` with durable preparation source (`manual` or `automatic`), request timestamp, and optional completion timestamp. Decode legacy records safely, then prune jobs whose local file no longer exists.
- Add `isReadyOffline(episodeID:feedURL:)`, requiring a local file and usable terminal analysis. Keep it separate from `isReadyForSeamlessPlay`, whose cleaning-off shortcut is insufficient for Ready to Play.
- Reconcile persisted jobs against local files at launch. A stale `.ready` job without audio must not appear in Ready to Play.

Create a pure `QueueStatusResolver` which implements mini-player priority and formats friendly copy. Retire the current numbered `1/4` through `4/4` compact labels from listener UI. Keep automatic background work quiet: it contributes to the Queue summary and only occupies the mini-player line when it is the next listening risk.

Keep network policy outside `WarmPlanner`. An injected `AutomaticDownloadEligibilityPolicy` returns eligible, Wi-Fi-blocked, or requires-first-cellular-consent; `AppShellModel` owns the resulting alert. `WarmPlanner` remains a UI-free serial executor of already-ranked requests.

### Browse-list integration

Update UIKit episode cells and SwiftUI podcast detail views to call the same `addAndPrepare` operation.

- Initial: **Add & Prepare**
- Queued: **In Up Next**
- Prepared but not queued: **Add to Up Next**
- No separate Download button and no duplicate Up Next component

## Validation

### Unit tests

- Queue add, move, remove, clear/restore, and immediate-playback repositioning.
- First Up Next item not ready while a later item is ready: autoplay waits rather than reordering the listener's queue.
- Removing an incomplete entry cancels work; removing a completed entry retains it in Ready to Play.
- Preserve manual order even if later entries become ready first.
- Require both a local file and completed analysis for Ready to Play eligibility.
- Verify status priority: current recovery, unfinished Up Next, automatic work, summary.
- Verify every job stage's friendly copy and download progress formatting.
- Verify twelve manual Add & Prepare requests complete without automatic caps; verify automatic work remains bounded and sustains two ready candidates.
- Verify cellular prompt policy, Wi-Fi-only behavior, and explicit-action bypass.
- Verify download deletion removes every associated queue/job/presentation state.

### UI and integration tests

- Library, Queue, and Discover tabs remain visible and hittable with a mini-player.
- Queue retains the mini-player; its Queue line opens the Queue tab.
- Up Next shows persistent drag grips, per-row status, and download progress.
- Reordering survives relaunch.
- Verify the visible drag grip genuinely reorders (rather than being decorative); use permanent internal `List` edit mode for Up Next if native SwiftUI move behavior provides the required handle.
- Tapping Up Next or Ready to Play starts the selected episode and preserves the interrupted episode at queue front.
- More menus expose only the appropriate section actions.
- Clear Up Next preserves ready downloads and Undo restores exact order.
- Cold restoration starts no analysis until interaction while restored playback markers and Queue remain available.

## Defaults

- Queue is a third tab, not a sheet.
- Mini-player is global except in full-player presentation.
- Manual order always wins over readiness.
- Drag handles are always visible.
- Removing from Up Next preserves downloads; only Remove download deletes them.
- Explicit preparation is unlimited and prioritized; automatic preparation is bounded.
