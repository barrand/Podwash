# Preparation Failure Recovery

## Outcome

When episode preparation reaches the terminal `needsAttention` state, PodWash
must tell the listener what failed and provide every safe action that can move
them forward. The experience must use the same failure meaning and recovery
behavior in Library, Queue, the mini player, and the full player.

This change is intentionally narrow. The app already has retry scheduling,
original-audio playback, durable preparation jobs, and safe cloud failure
categories. The work is to classify terminal failures accurately, connect the
existing actions to the failed player state, and present one shared explanation.

Success means:

- No terminal preparation state displays only “Preparation needs attention.”
- A listener can open a compact explanation from every surface that shows the
  failure.
- Retry re-enters the existing single-worker preparation path without starting
  duplicate download or analysis work.
- When verified local audio exists, the listener can play the original audio
  without claiming that clean playback is ready.
- Listener-facing diagnostics contain no raw exception, URL, credential,
  transcript, request, or response data.

## Product behavior

### Shared issue sheet

Present one medium-height sheet titled **Couldn’t prepare this episode**. It
contains:

1. The episode title.
2. One plain-language explanation from the mapping below.
3. A visible, selectable diagnostic code.
4. The applicable recovery buttons, followed by **Done**.

Use these actions:

- **Try Again** resets the failed job and submits it to the existing scheduler.
- **Play Original Audio** starts the verified local file with no cleaning or ad
  skipping, then dismisses the issue sheet.
- **Done** dismisses the sheet without changing the job.

Do not add a Settings action. Cloud processing being disabled is already a
valid locally-ready outcome (“Ad checks are off”), not a terminal failure.
Build configuration, authentication, and credential failures are not fixable
through listener settings.

### Failure mapping

| Failure reason | Short status | Sheet explanation | Code | Try Again | Original audio |
| --- | --- | --- | --- | --- | --- |
| No downloadable audio | **Audio unavailable** | “The publisher did not provide downloadable audio for this episode, so PodWash can’t prepare it.” | `PW-PREP-NO-AUDIO` | No | No |
| Download failed | **Download failed** | “PodWash couldn’t download the episode. Check your connection and try again.” | `PW-PREP-DOWNLOAD` | Yes | No |
| Local preparation failed | **Local preparation failed** | “The episode downloaded, but PodWash couldn’t finish preparing clean playback.” | `PW-PREP-LOCAL` | Yes | Yes, when a verified local file exists |
| Terminal cloud failure | **Ad check failed** | “The episode downloaded, but the ad check couldn’t finish. You can try again or play the original audio.” | `PW-PREP-CLOUD-{CATEGORY}` | Yes | Yes, when a verified local file exists |

`{CATEGORY}` is the uppercased stable raw value of
`CloudAdDetectionFailureCategory`, normalized to ASCII hyphenated text. For
example, `invalidResponse` becomes `PW-PREP-CLOUD-INVALID-RESPONSE`. These codes
are identifiers, not localized prose.

Transient cloud failures (`network`, `rateLimited`, `serviceUnavailable`, and
`timeout`) continue to use `adCheckDelayed` and automatic backoff. They do not
open the terminal issue experience unless the retry policy separately decides
that retries are exhausted in the future.

### Entry points

- **Library and Queue rows:** retain the existing primary **Retry** control for
  retryable terminal failures. Render the mapped short status instead of the
  generic message. Add **View Issue** to More for every terminal failure.
  `noDownloadableAudio` has no primary Retry control; use the warning icon as a
  passive control and expose **View Issue** in More.
- **Mini player:** when `playbackReadiness == .failed`, tapping the mini-player
  body opens the issue sheet instead of expanding a player that cannot play.
  Keep the Queue status strip behavior unchanged.
- **Full player:** replace the static failure text with the mapped short status
  and a **View Issue** button.

The sheet is the only location for long-form failure copy and fallback actions.
Rows and players remain compact.

## Data and state contract

### Typed terminal reason

Add this internal, persisted type near `AnalysisJob`:

```swift
enum PreparationFailureReason: Codable, Equatable, Sendable {
    case noDownloadableAudio
    case downloadFailed
    case localPreparationFailed
    case cloud(CloudAdDetectionFailureCategory)
}
```

Add an optional property to `AnalysisJob`:

```swift
var failureReason: PreparationFailureReason? = nil
```

The property must remain optional so JSON written by the existing
`AnalysisJobStore` decodes without a migration. Keep `detail` because it is
also used for nonterminal status such as automatic retry. New terminal writers
must set `failureReason`; `detail` may retain short compatibility copy but must
not control available actions.

When reading an old persisted `needsAttention` job whose `failureReason` is
missing, map its exact legacy details as follows:

- `No downloadable audio` -> `.noDownloadableAudio`
- `Download failed` -> `.downloadFailed`
- `Local preparation failed` -> `.localPreparationFailed`
- A non-nil `cloudFailure` -> `.cloud(cloudFailure)`
- Anything else -> `.localPreparationFailed`

This compatibility mapping belongs in one resolver, not in SwiftUI views. The
next job transition will persist the typed reason normally.

### Presentation value

Add a pure value used by all UI surfaces:

```swift
struct PreparationIssue: Identifiable, Equatable {
    let episodeID: String
    let episodeTitle: String
    let reason: PreparationFailureReason
    let hasVerifiedLocalAudio: Bool

    var id: String { episodeID }
}

struct PreparationIssuePresentation: Equatable {
    let shortStatus: String
    let explanation: String
    let diagnosticCode: String
    let allowsRetry: Bool
    let allowsOriginalPlayback: Bool
}
```

Implement a pure mapper from `PreparationIssue` to
`PreparationIssuePresentation`. `allowsOriginalPlayback` is true only when the
reason permits fallback and `hasVerifiedLocalAudio` is true. Never infer local
audio from a job stage; ask `DownloadManager` for a verified local URL through
the same path used by existing playback eligibility.

`EpisodeAvailability` / `EpisodeReadinessStatus` should carry the typed reason
for `needsAttention` instead of only a display string. Update equality and
presentation mapping accordingly. This prevents Queue and Library from
reconstructing business state from prose.

### Failure classification

Update every terminal writer in `WarmPlanner`:

- Missing enclosure URL -> `.noDownloadableAudio`
- Missing/failed verified download -> `.downloadFailed`
- Analysis did not produce a valid local artifact and there is no cloud failure
  outcome -> `.localPreparationFailed`
- A nonretryable `lastCloudAdDetectionOutcome` -> `.cloud(category)`

Correct foreground preparation in `AppShellModel` at the same time. Do not call
`CloudAdDetectionFailureCategory.classify(error)` for an arbitrary caught
error: its fallback is `.network`, which can mislabel a local analysis failure
and incorrectly schedule cloud retry. In the catch path:

1. If `AnalysisPipeline.lastCloudAdDetectionOutcome` is `.failed(category)`,
   apply the existing retryable/nonretryable cloud policy.
2. Otherwise publish terminal `.localPreparationFailed`.

Only known cloud failures may become `adCheckDelayed`. Cancellation remains a
resumable interruption and must not become a terminal issue.

Apply the same rule to `startRestoredRecoveryIfNeeded`; it currently classifies
any caught error as a cloud failure too. `CloudAdDetectionFailureCategory.classify`
should be called only at the cloud-client/transport boundary where the error is
known to come from the cloud request.

## UI and action wiring

### Shell-owned presentation

Follow the existing transcript-sheet ownership pattern:

- Add `preparationIssueEpisodeID: String?` to `AppShellModel`.
- Expose a computed `presentedPreparationIssue` that re-resolves the current
  job, episode title, and verified local-file state each time it is read.
- Add `presentPreparationIssue(episodeID:)` and
  `dismissPreparationIssue()` commands.
- Host a single `.sheet(item:)` in `AppShellView`. If the full player is already
  presented, attach the same sheet content inside that player navigation stack,
  as the transcript viewer does, so SwiftUI never attempts two root sheets at
  once.
- Clear the issue selection if the episode is removed, unsubscribed, or the job
  leaves `needsAttention` while the sheet is open.

Add `.viewPreparationIssue` to `EpisodeMenuAction`. `EpisodeMenuPolicy` includes
it for every `needsAttention` status before transcript and played-state actions.
The existing row Retry closure remains the retry implementation for retryable
reasons.

Pass `onViewPreparationIssue` into `MiniPlayerBar` and
`PlaybackControlsView`. Do not let either view inspect `AnalysisJob` or cloud
categories directly; they render the shared presentation supplied by the
model.

### Retry semantics

Use `retryEpisodePreparation(_:)` as the single listener-facing retry command.
It has two execution branches after dismissing the issue sheet and clearing
terminal metadata:

- **Queue/Library job:** reset through `WarmPlanner.resetJobForRetry`, restore
  explicit ownership with `requestExplicitPreparation`, and rebuild the one
  scheduler worker.
- **Current foreground episode:** restart foreground preparation against the
  existing local file and `PlaybackCoordinator`. Do not send this branch to
  `WarmPlanner`: `scheduleWarmForComingUp` deliberately excludes the current
  episode, so doing so would leave the player failed forever.

Extract the analysis-launching portion of `beginPlaybackSession` into a private
`startForegroundPreparation` helper that both initial playback and foreground
retry call. The helper accepts the already-resolved episode/playback context,
uses the existing engine and coordinator, creates a new request generation,
sets `playbackReadiness = .preparing`, publishes a fresh foreground job, and
owns `playbackPreparationTask`. Retry must keep the player visible and paused;
it must not tear down and rebuild the playback engine.

Before calling the helper, foreground retry must call
`invalidatePlaybackPreparation()` so the failed task cannot publish late state.
Then it must:

1. Revalidate `activePlaybackContext`, `nowPlayingEpisodeID`, the verified local
   URL, and `playbackCoordinator`.
2. Clear terminal reason, detail, cloud failure, retry deadline, and retry count.
3. Start exactly one replacement foreground preparation task.

Do not create a second analyzer, direct download, or sheet-specific retry path.
Repeated taps must be idempotent.

### Original playback semantics

Use the existing `.original` local playback mode. The sheet action must call a
model command that re-verifies the local file immediately before playback. If
the file disappeared while the sheet was open, leave playback stopped and
refresh the issue so the fallback button disappears.

Original playback:

- does not mark preparation ready;
- does not write clean intervals;
- does not enable profanity removal or ad skipping;
- dismisses the issue sheet after playback is successfully staged;
- retains the failed job so the listener can retry preparation later.

## Accessibility and analytics

- Give the sheet title heading semantics.
- Read the explanation before the code and actions.
- Give the code the accessibility label “Preparation error code” and make its
  text selectable; a separate clipboard button is unnecessary.
- Preserve 44-point targets and Dynamic Type wrapping.
- Add identifiers for the sheet, code, Try Again, and Play Original Audio.
- Record `Preparation.issueViewed`, `Preparation.retry`, and
  `Preparation.playOriginal` actions. Do not include diagnostic code, category,
  episode ID, or error text in analytics payloads.

## Verification

### Unit tests

Add table-driven tests covering:

- Every `PreparationFailureReason` maps to the exact status, explanation, and
  diagnostic code above.
- Retry is disabled only for `noDownloadableAudio`.
- Original playback is offered only for local/cloud failures with a verified
  local file.
- Old stored jobs without `failureReason` decode and receive the compatibility
  mapping.
- Unknown non-cloud foreground errors become `localPreparationFailed`, never
  `adCheckDelayed`.
- Known transient cloud categories retain automatic retry; known terminal cloud
  categories produce `.cloud(category)`.
- Episode menu policy includes **View Issue** for terminal failures and does not
  offer a duplicate Retry menu item when Retry is already the primary control.
- Retry clears terminal metadata and cannot create concurrent analysis work.
- Original playback refuses a stale or missing local file and leaves the job
  failed.

Prefer extending `AnalysisJobTests`, `EpisodeDownloadAffordanceTests`, and the
existing `AppShellModel` / `WarmPlanner` test suites rather than creating UI
logic tests around SwiftUI internals.

### UI tests

Add deterministic fixture states for terminal local failure and terminal cloud
failure. Verify two end-to-end flows:

1. Open **View Issue** from a failed row, assert the exact explanation and code,
   tap **Try Again**, and observe the row leave `needsAttention`.
2. Tap a failed mini player, assert that the issue sheet opens, choose **Play
   Original Audio**, and verify playback begins while the job remains failed.

Also verify the no-audio fixture omits both recovery buttons and exposes the
explanation and diagnostic code.

## Out of scope

- Raw error or server-response display.
- A support/contact workflow or copy-to-clipboard button.
- Changing cloud retry delays or retry exhaustion policy.
- Making cloud-processing opt-out a failure.
- Retrying only a substage of local transcription unless the existing pipeline
  already has a valid checkpoint.
- Redesigning Queue, Library rows, or the player outside their failed state.
